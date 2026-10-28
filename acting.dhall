{-
nixos-config/acting.dhall — every operational script in this repository (`*.sh`,
`*.py`), classified, with a ceiling per class. What the classes mean and when a
ceiling may rise: ../dev-lint/tables/acting_schema.dhall. The gate runs
`dev-lint-fleet --acting .`: a script with no row, a row for a file that is
gone, or a class over its ceiling fails the commit that causes it. Raise a
ceiling in the same commit as the file, with the reason beside it.
-}
let A = ../dev-lint/tables/acting_schema.dhall

let subject = A.subject

let Class = A.Class

in  { ceilings =
      { acts = 0
      , bootstrap = 2
      , by_design = 0
      , observes = 7
      , observer_checks = 0
      }
    , subjects =
          [ subject "machines/amun/test_vpn_nodes.py" Class.Test ""
          , subject
              "machines/amun/vpn-nodes-push.py"
              Class.Observes
              "reads `wg show` on the hub and pushes each peer's liveness to fleetwatch; it changes nothing, so by this table's axis it observes. A plan would own it only if a peer being down had a remedy here, and it has none"
          , subject "machines/odin/backup_preview.py" Class.Observes ""
          , subject
              "plan-fleetwatch-push.py"
              Class.Observes
              "runs a plan read-only (--simulate) and reports its verdict"
          , subject "scripts/eval_machines.py" Class.Observes ""
          , subject "scripts/firewall_order.py" Class.Observes ""
          , subject "scripts/render_clusters.py" Class.Observes ""
          , subject "scripts/setup-hooks.sh" Class.Bootstrap ""
          , subject "scripts/ssh_config_order.py" Class.Observes ""
          , subject "scripts/test_firewall_order.py" Class.Test ""
          , subject "scripts/test_ssh_config_order.py" Class.Test ""
          , subject "setup.sh" Class.Bootstrap ""
          , subject "test_plan_fleetwatch_push.py" Class.Test ""
          ]
        : List A.Subject
    }
