use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

use amaru_bootstrap::{bootstrap, S3Config};
use amaru_node::{
    build_and_run_node, path_is_populated, submit_api, LogFormat, NetworkName, NodeBuilder,
    Telemetry, TelemetryOptions,
};
use serde_json::json;
use tauri::{AppHandle, Manager, RunEvent};
use tauri_plugin_store::StoreExt;
use tokio_util::sync::CancellationToken;

const NODE_LISTEN_ADDRESS: &str = "0.0.0.0:3000";
const SUBMIT_API_ADDRESS: &str = "127.0.0.1:3001";
const SUBMIT_API_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(target_os = "ios")]
const RAYON_WORKER_STACK_SIZE: usize = 10_000_000;

#[cfg(target_os = "ios")]
fn configure_parallel_runtime() {
    rayon::ThreadPoolBuilder::new()
        .stack_size(RAYON_WORKER_STACK_SIZE)
        .build_global()
        .expect("failed to configure the global Rayon thread pool");
}

#[cfg(not(target_os = "ios"))]
fn configure_parallel_runtime() {}

fn ledger_dir(app: &AppHandle) -> PathBuf {
    app.path()
        .app_data_dir()
        .expect("no app data dir")
        .join("ledger.db")
}

fn chain_dir(app: &AppHandle) -> PathBuf {
    app.path()
        .app_data_dir()
        .expect("no app data dir")
        .join("chain.db")
}

fn bootstrap_cache_dir(app: &AppHandle) -> PathBuf {
    app.path()
        .app_cache_dir()
        .expect("no app cache dir")
        .join("amaru-bootstrap")
}

struct WorkingDirectoryGuard(PathBuf);

impl WorkingDirectoryGuard {
    fn change_to(path: &Path) -> std::io::Result<Self> {
        std::fs::create_dir_all(path)?;
        let previous = std::env::current_dir()?;
        std::env::set_current_dir(path)?;
        Ok(Self(previous))
    }
}

impl Drop for WorkingDirectoryGuard {
    fn drop(&mut self) {
        if let Err(error) = std::env::set_current_dir(&self.0) {
            eprintln!("Failed to restore working directory: {error}");
        }
    }
}

#[tauri::command]
fn clear_app_data_dir(app: AppHandle) -> Result<(), String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;

    if dir.exists() {
        std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    }

    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Amaru validates Plutus scripts in Rayon's global pool. Some scripts have
    // deeply nested UPLC terms that overflow iOS' default worker-thread stack.
    configure_parallel_runtime();

    // Telemetry reads these before any Amaru tasks start. Keep explicit user
    // configuration when the application is launched with overrides.
    if std::env::var_os("AMARU_WITH_OPEN_TELEMETRY").is_none() {
        std::env::set_var("AMARU_WITH_OPEN_TELEMETRY", "true");
    }
    if std::env::var_os("OTEL_EXPORTER_OTLP_ENDPOINT").is_none() {
        std::env::set_var("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4317");
    }

    let shutdown = CancellationToken::new();
    let node_thread = Arc::new(Mutex::new(None));
    let node_thread_for_setup = Arc::clone(&node_thread);
    let node_shutdown = shutdown.clone();

    let app = tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_keep_screen_on::init())
        .setup(move |app| {
            let app_data_dir = app.path().app_data_dir()?;
            let app_cache_dir = app.path().app_cache_dir()?;
            std::fs::create_dir_all(&app_data_dir)?;
            std::fs::create_dir_all(&app_cache_dir)?;

            let store = app.store("store.json")?;
            store.set("network", json!({ "value": "PreProd" }));

            #[cfg(debug_assertions)]
            if let Some(window) = app.get_webview_window("main") {
                window.open_devtools();
            }

            let otel_db = app_data_dir.join("otel.db");
            otel_ui_backend::spawn(otel_db);

            let thread = launch_amaru(
                app.handle().clone(),
                NetworkName::Preprod,
                node_shutdown.clone(),
            );
            *node_thread_for_setup.lock().expect("node thread lock") = Some(thread);

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![clear_app_data_dir])
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(move |_app, event| match event {
        RunEvent::ExitRequested { .. } => shutdown.cancel(),
        RunEvent::Exit => {
            shutdown.cancel();
            if let Some(thread) = node_thread.lock().expect("node thread lock").take() {
                let _ = thread.join();
            }
        }
        _ => {}
    });
}

fn peers_for_network(network: NetworkName) -> Vec<String> {
    match network {
        NetworkName::Mainnet => vec!["relays.cardano-mainnet.iohk.io:3001".into()],
        NetworkName::Preprod => vec!["preprod-node.play.dev.cardano.org:3001".into()],
        NetworkName::Preview => vec![
            "preview-node.play.dev.cardano.org:3001".into(),
            "relays.cardano-preview.iohkdev.io:3001".into(),
        ],
        _ => vec![],
    }
}

fn launch_amaru(
    app: AppHandle,
    network: NetworkName,
    shutdown: CancellationToken,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("icarus-amaru")
            .thread_stack_size(8 * 1024 * 1024)
            .build()
            .expect("create Amaru runtime");

        if let Err(error) = runtime.block_on(run_amaru(&app, network, shutdown)) {
            eprintln!("Amaru stopped: {error}");
        }
    })
}

async fn run_amaru(
    app: &AppHandle,
    network: NetworkName,
    shutdown: CancellationToken,
) -> Result<(), Box<dyn std::error::Error>> {
    let telemetry = Telemetry::install_with_options(
        LogFormat::Plain,
        TelemetryOptions {
            // sysinfo cannot enumerate the application process inside the iOS
            // sandbox. Amaru's remaining traces, logs, and node metrics stay on.
            collect_system_metrics: !cfg!(target_os = "ios"),
        },
    )
    .await?;
    let ledger_dir = ledger_dir(app);
    let chain_dir = chain_dir(app);
    let bootstrap_cache_dir = bootstrap_cache_dir(app);

    bootstrap_if_needed(network, &ledger_dir, &chain_dir, &bootstrap_cache_dir).await?;

    let mut config = NodeBuilder::new(network)?
        .ledger_dir(ledger_dir)
        .chain_dir(chain_dir)
        .peers(peers_for_network(network))
        .without_embedded_peer_snapshot()
        .listen_address(NODE_LISTEN_ADDRESS)
        .migrate_chain_db(true)
        .meter(Arc::clone(&telemetry.meter))
        .build()?;

    // Preserve Icarus's pre-migration memory profile. The release defaults to
    // three 20 MiB arenas, which needs separate qualification on mobile.
    config.ledger_config.ledger_vm_alloc_arena_count = 1;
    config.ledger_config.ledger_vm_alloc_arena_size = 1_024_000;

    let running = build_and_run_node(config, &tokio::runtime::Handle::current())?;
    let submit_shutdown = shutdown.child_token();
    let submit_address: SocketAddr = SUBMIT_API_ADDRESS.parse()?;
    let (submit_handle, _) = submit_api::start(
        submit_address,
        running.mempool_sender(),
        submit_shutdown.clone(),
    )
    .await?;

    tokio::select! {
        _ = shutdown.cancelled() => running.request_abort(),
        _ = running.termination() => {
            return Err("Amaru node terminated unexpectedly".into());
        }
    }

    running.termination().await;
    submit_shutdown.cancel();
    if tokio::time::timeout(SUBMIT_API_SHUTDOWN_TIMEOUT, submit_handle)
        .await
        .is_err()
    {
        eprintln!("Submit API did not stop within five seconds");
    }
    telemetry.shutdown().await?;

    Ok(())
}

async fn bootstrap_if_needed(
    network: NetworkName,
    ledger_dir: &Path,
    chain_dir: &Path,
    bootstrap_cache_dir: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    match (
        path_is_populated(ledger_dir)?,
        path_is_populated(chain_dir)?,
    ) {
        (true, true) => Ok(()),
        (false, false) => {
            let global_parameters = network.as_global_parameters().cloned().ok_or_else(|| {
                std::io::Error::other(format!(
                    "global parameters are unavailable for network {network}"
                ))
            })?;

            // amaru-bootstrap v10.11 stores downloads in the relative path
            // `snapshots/<network>` and does not expose a directory override.
            // Scope it to the platform cache directory; the iOS application
            // working directory is inside the read-only app bundle.
            let _working_directory = WorkingDirectoryGuard::change_to(bootstrap_cache_dir)?;
            bootstrap(
                network,
                &global_parameters,
                ledger_dir.to_path_buf(),
                chain_dir.to_path_buf(),
                None,
                S3Config::default(),
            )
            .await?;

            Ok(())
        }
        _ => Err(
            "ledger and chain stores are only partially populated; reset application data before restarting"
                .into(),
        ),
    }
}
