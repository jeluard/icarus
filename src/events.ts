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
    kind: "downloaded_snapshot";
  }
  | {
    kind: "importing_snapshot";
    snapshot: string;
  }
  | {
    kind: "imported_snapshot";
  };

export type RuntimeEvent =
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