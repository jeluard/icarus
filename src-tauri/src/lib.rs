use amaru::{
    bootstrap::bootstrap,
    stages::{build_and_run_network, Config},
};
use amaru_kernel::{Epoch, Slot, network::NetworkName};
use amaru_stores::rocksdb::RocksDbConfig;
use amaru_tracing_json::{JsonLayer, JsonTraceCollector};
use serde::Serialize;
use serde_json::json;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_store::StoreExt;
use tracing::Dispatch;
use tracing_subscriber::layer::SubscriberExt;

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

#[derive(Serialize, Debug, Clone)]
#[serde(tag = "type", content = "payload")]
pub enum AppEvent {
    #[serde(rename = "bootstrap")]
    Bootstrap(BootstrapEvent),

    #[serde(rename = "runtime")]
    Runtime(RuntimeEvent),
}

#[derive(Serialize, Debug, Clone)]
#[serde(tag = "kind")]
pub enum BootstrapEvent {
    #[serde(rename = "downloading_snapshot")]
    DownloadingShapshot { epoch: Epoch },

    #[serde(rename = "snapshots_downloaded")]
    SnapshotsDownloaded {},

    #[serde(rename = "importing_snapshots")]
    ImportingSnapshots {},

    #[serde(rename = "importing_snapshot")]
    ImportingSnapshot { snapshot: String },

    #[serde(rename = "imported_snapshot")]
    ImportedSnapshot { epoch: Epoch },

    #[serde(rename = "imported_snapshots")]
    ImportedSnapshots {},
}

#[derive(Serialize, Debug, Clone)]
#[serde(tag = "kind")]
pub enum RuntimeEvent {
    #[serde(rename = "starting")]
    Starting { tip: Slot },

    #[serde(rename = "creating_state")]
    CreatingState {},

    #[serde(rename = "epoch_transition")]
    EpochTransition { from: Epoch, into: Epoch },

    #[serde(rename = "tip_caught_up")]
    TipCaughtUp { slot: Slot },

    #[serde(rename = "tip_syncing")]
    TipSyncing { slot: Slot },
}

fn slot_from_point(line: &serde_json::Value, field: &str) -> Slot {
    line.get(field)
        .unwrap_or(&serde_json::Value::Null)
        .as_str()
        .and_then(|obj| obj.split(".").next())
        .and_then(|slot_val| slot_val.parse::<u64>().ok())
        .unwrap_or_default()
        .into()
}

fn emit_logs(app: &tauri::AppHandle, line: serde_json::Value) {
    let name = line
        .get("name")
        .unwrap_or_default()
        .as_str()
        .unwrap_or_default();
    let event = match name {
        "Downloading snapshot" => {
            let epoch = line
                .get("epoch")
                .unwrap_or_default()
                .as_str()
                .unwrap_or_default()
                .parse()
                .unwrap_or_default();
            Some(AppEvent::Bootstrap(BootstrapEvent::DownloadingShapshot {
                epoch,
            }))
        }
        "All snapshots downloaded and decompressed successfully" => {
            Some(AppEvent::Bootstrap(BootstrapEvent::SnapshotsDownloaded {}))
        }
        "Importing snapshots" => Some(AppEvent::Bootstrap(BootstrapEvent::ImportingSnapshots {})),
        "Importing snapshot" => {
            let snapshot = line
                .get("snapshot")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string();
            Some(AppEvent::Bootstrap(BootstrapEvent::ImportingSnapshot {
                snapshot,
            }))
        }
        "Imported snapshot" => {
            let epoch = line
                .get("epoch")
                .unwrap_or_default()
                .as_str()
                .unwrap_or_default()
                .parse()
                .unwrap_or_default();
            Some(AppEvent::Bootstrap(BootstrapEvent::ImportedSnapshot {
                epoch,
            }))
        }
        "Imported snapshots" => Some(AppEvent::Bootstrap(BootstrapEvent::ImportedSnapshots {})),
        "starting" => {
            // tip":{"hash":"d6fe6439aed8bddc10eec22c1575bf0648e4a76125387d9e985e9a3f8342870d","slot":70070379}
            let tip = line
                .get("tip")
                .unwrap_or_default()
                .as_object()
                .unwrap()
                .get("slot")
                .unwrap_or_default()
                .as_u64()
                .unwrap_or_default()
                .into();
            Some(AppEvent::Runtime(RuntimeEvent::Starting { tip }))
        }
        "new.known_snapshots" => Some(AppEvent::Runtime(RuntimeEvent::CreatingState {})),
        "epoch_transition" => {
            let from = line
                .get("from")
                .unwrap_or_default()
                .as_u64()
                .unwrap_or_default()
                .into();
            let into = line
                .get("into")
                .unwrap_or_default()
                .as_u64()
                .unwrap_or_default()
                .into();
            Some(AppEvent::Runtime(RuntimeEvent::EpochTransition {
                from,
                into,
            }))
        }
        "track_peers.caught_up.new_tip" => {
            let slot = slot_from_point(&line, "point");
            Some(AppEvent::Runtime(RuntimeEvent::TipCaughtUp { slot }))
        }
        "track_peers.syncing.new_tip" => {
            let slot = slot_from_point(&line, "point");
            Some(AppEvent::Runtime(RuntimeEvent::TipSyncing { slot }))
        }
        _ => None,
    };
    let _ = if let Some(event) = event {
        let _ = app.emit("amaru", event);
    };
}

#[tauri::command]
fn clear_app_data_dir(app: AppHandle) -> Result<(), String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;

    if dir.exists() {
        std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    }

    Ok(())
}

#[tauri::command]
fn clear_dbs(app: AppHandle) -> Result<(), String> {
    let ledger_dir = ledger_dir(&app);

    if ledger_dir.exists() {
        std::fs::remove_dir_all(&ledger_dir).map_err(|e| e.to_string())?;
    }

    let chain_dir = chain_dir(&app);

    if ledger_dir.exists() {
        std::fs::remove_dir_all(&chain_dir).map_err(|e| e.to_string())?;
    }

    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let collector = JsonTraceCollector::default();
    let layer = JsonLayer::new(collector.clone());
    let subscriber = tracing_subscriber::registry().with(layer);
    let dispatch = Dispatch::new(subscriber);
    let _guard = tracing::dispatcher::set_global_default(dispatch);

    tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_keep_screen_on::init())
        .setup(|app| {
            let store = app.store("store.json")?;
            store.set("network", json!({ "value": "PreProd" }));

            let window = app.get_webview_window("main").unwrap();
            window.open_devtools();

            let app_handle = app.handle().clone();

            //      clear_app_data_dir(app_handle.clone()).ok();
            //      clear_dbs(app_handle.clone()).ok();

            tauri::async_runtime::spawn(async move {
                launch_amaru(app_handle.clone(), NetworkName::Preprod);
                loop {
                    let lines = collector.flush();
                    for line in lines {
                        emit_logs(&app_handle, line);
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                }
            });

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
    std::thread::Builder::new()
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            let rt = tokio::runtime::Runtime::new().unwrap();
            rt.block_on(async {
                let ledger_dir = ledger_dir(&app);
                let chain_dir = chain_dir(&app);
                if !ledger_dir.exists() {
                    bootstrap(
                        network,
                        ledger_dir.clone(),
                        chain_dir.clone(),
                    )
                    .await
                    .unwrap();
                }
                let config = Config {
                    upstream_peers: peers_for_network(network),
                    ledger_store: amaru::stages::StoreType::RocksDb(RocksDbConfig::new(ledger_dir)),
                    chain_store: amaru::stages::StoreType::RocksDb(RocksDbConfig::new(chain_dir)),
                    migrate_chain_db: true,
                    ..Config::default()
                };

                match build_and_run_network(config, None).await {
                    Ok(running) => running.join().await,
                    Err(e) => eprintln!("Bootstrap failed: {}", e),
                }
            });
        })
        .unwrap();
}
