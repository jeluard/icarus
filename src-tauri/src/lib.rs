use amaru::{
    bootstrap::bootstrap,
    observability::{ObservabilityHints, TracingSubscriber, setup_open_telemetry},
    stages::{build_node::build_and_run_node, config::{Config, StoreType}},
};
use amaru_kernel::NetworkName;
use amaru_stores::rocksdb::RocksDbConfig;
use serde_json::json;
use tauri::{AppHandle, Manager};
use tauri_plugin_store::StoreExt;

fn ledger_dir(app: &tauri::AppHandle) -> std::path::PathBuf {
    app.path()
        .app_data_dir()
        .expect("no app data dir")
        .join("ledger.db")
}

fn chain_dir(app: &tauri::AppHandle) -> std::path::PathBuf {
    app.path()
        .app_data_dir()
        .expect("no app data dir")
        .join("chain.db")
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
    tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_keep_screen_on::init())
        .setup(|app| {
            let store = app.store("store.json")?;
            store.set("network", json!({ "value": "PreProd" }));

            #[cfg(debug_assertions)]
            if let Some(window) = app.get_webview_window("main") {
                window.open_devtools();
            }

            let otel_db = app.path().app_data_dir().expect("no app data dir").join("otel.db");
            otel_ui_backend::spawn(otel_db);

            launch_amaru(app.handle().clone(), NetworkName::Preprod);

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![clear_app_data_dir])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn peers_for_network(network: NetworkName) -> Vec<String> {
    match network {
        NetworkName::Mainnet => vec![
            "relays.cardano-mainnet.iohk.io:3001".into(),
        ],
        NetworkName::Preprod => vec![
            "preprod-node.play.dev.cardano.org:3001".into(),
        ],
        NetworkName::Preview => vec![
            "preview-node.play.dev.cardano.org:3001".into(),
            "relays.cardano-preview.iohkdev.io:3001".into(),
        ],
        _ => vec![],
    }
}

fn launch_amaru(app: AppHandle, network: NetworkName) {
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_stack_size(8 * 1024 * 1024)
            .build()
            .unwrap();
        rt.block_on(async {
                // Set up OpenTelemetry — exports to otel-ui-backend on localhost:4317 (gRPC)
                struct Hints;
                impl ObservabilityHints for Hints {
                    fn listen_address(&self) -> Option<&str> {
                        None
                    }
                }
                let mut subscriber = TracingSubscriber::new();
                let (otel_handle, _) = setup_open_telemetry(&mut subscriber, &Hints);
                subscriber.init(false);

                let ledger_dir = ledger_dir(&app);
                let chain_dir = chain_dir(&app);
                if !ledger_dir.exists() {
                    bootstrap(
                        network,
                        ledger_dir.clone(),
                        chain_dir.clone(),
                        None,
                    )
                    .await
                    .unwrap();
                }
                let config = Config {
                    upstream_peers: peers_for_network(network),
                    ledger_store: RocksDbConfig::new(ledger_dir),
                    chain_store: StoreType::RocksDb(RocksDbConfig::new(chain_dir)),
                    migrate_chain_db: true,
                    network,
                    submit_api_address: Some("127.0.0.1:3001".to_string()),
                    ..Config::default()
                };

                let submit_api_addr = config.submit_api_address().ok().flatten();

                match build_and_run_node(config, otel_handle.metrics) {
                    Ok(running) => {
                        let exit = amaru::exit::hook_exit_token();
                        if let Some(addr) = submit_api_addr {
                            if let Err(e) = amaru::submit_api::start(addr, running.mempool_sender(), exit.child_token()).await {
                                eprintln!("Submit API failed to start: {e}");
                            }
                        }
                        running.termination().await
                    },
                    Err(e) => eprintln!("Node start failed: {}", e),
                }
            });
    });
}
