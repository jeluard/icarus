export type AppEvent =
  | {
    type: "bootstrap";
    payload: BootstrapEvent;
  }
  | {
    type: "runtime";
    payload: RuntimeEvent;
  };

export type BootstrapEvent =
  | {
    kind: "downloading_snapshot";
    epoch: number;
  }
  | {
    kind: "snapshots_downloaded";
  }
  | {
    kind: "importing_snapshots";
  }
  | {
    kind: "importing_snapshot";
    snapshot: string;
  }
  | {
    kind: "imported_snapshot";
  }
  | {
    kind: "imported_snapshots";
  };

export type RuntimeEvent =
  | {
    kind: "starting";
    tip: number;
  }
  | {
    kind: "creating_state";
  }
  | {
    kind: "epoch_transition";
    from: number;
    into: number;
  }
  | {
    kind: "tip_caught_up";
    slot: number;
  }
  | {
    kind: "tip_syncing";
    slot: number;
  };