{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.jellarr;
  bootstrapCfg = cfg.bootstrap;
  bootstrapEnabled = cfg.enable && bootstrapCfg.enable;

  pkg = import ../package.nix {inherit lib pkgs;};
in {
  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd = {
        services.jellarr = {
          after =
            [
              "network-online.target"
              "systemd-tmpfiles-setup.service"
            ]
            ++ lib.optional bootstrapEnabled "jellarr-api-key-bootstrap.service";
          description = "Run jellarr (packaged) once";
          preStart = let
            configFile = pkgs.writeText "jellarr-config.yml" (pkgs.lib.generators.toYAML {} cfg.config);
          in
            # sh
            ''
              install -D -m 0644 ${configFile} ${cfg.dataDir}/config/config.yml
              chown ${cfg.user}:${cfg.group} ${cfg.dataDir}/config/config.yml

              for i in $(seq 1 120); do
                ${pkgs.curl}/bin/curl -sf ${cfg.config.base_url}/System/Info/Public >/dev/null && exit 0
                sleep 1
              done

              echo "Jellyfin not running or not ready at ${cfg.config.base_url}"

              exit 1
            '';
          serviceConfig = {
            EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
            ExecStart = lib.getExe pkg;
            Group = cfg.group;
            Type = "oneshot";
            User = cfg.user;
            WorkingDirectory = cfg.dataDir;
          };
          wants = ["network-online.target"];
        };

        timers.jellarr = {
          description = "Schedule jellarr run";
          partOf = ["jellarr.service"];
          timerConfig = {
            OnCalendar = cfg.schedule;
            Persistent = true;
            RandomizedDelaySec = "5m";
          };
          wantedBy = ["timers.target"];
        };

        tmpfiles.rules = [
          "d ${cfg.dataDir} 0755 ${cfg.user} ${cfg.group} -"
          "d ${cfg.dataDir}/config 0755 ${cfg.user} ${cfg.group} -"
        ];
      };

      users = {
        groups = lib.mkIf (cfg.group == "jellarr") {
          ${cfg.group} = {};
        };

        users = lib.mkIf (cfg.user == "jellarr") {
          jellarr = {
            description = "jellarr user";
            inherit (cfg) group;
            home = cfg.dataDir;
            isSystemUser = true;
          };
        };
      };
    })

    (lib.mkIf bootstrapEnabled {
      assertions = [
        {
          assertion = bootstrapCfg.apiKeyFile != null;
          message = "services.jellarr.bootstrap.apiKeyFile must be set when bootstrap is enabled.";
        }
      ];

      systemd.services.jellarr-api-key-bootstrap = {
        after = [bootstrapCfg.jellyfinService];
        description = "Bootstrap API key into Jellyfin database for Jellarr";
        path = [
          pkgs.coreutils
          pkgs.sqlite
          pkgs.systemd
        ];
        script = let
          dbPath = "${bootstrapCfg.jellyfinDataDir}/data/jellyfin.db";
        in
          # sh
          ''
            set -euo pipefail

            DB="${dbPath}"
            API_KEY=$(cat ${bootstrapCfg.apiKeyFile} | tr -d '[:space:]')
            API_KEY_NAME="${bootstrapCfg.apiKeyName}"

            until [ -e "$DB" ]; do
              sleep 1
            done

            # Check if key already exists - skip restart cycle if so
            existing=$(sqlite3 "$DB" "SELECT COUNT(*) FROM ApiKeys WHERE Name='$API_KEY_NAME';")
            if [ "$existing" -gt 0 ]; then
              echo "API key '$API_KEY_NAME' already exists, skipping Jellyfin restart"
              exit 0
            fi

            # Key doesn't exist - need to stop Jellyfin to safely insert
            echo "Inserting API key '$API_KEY_NAME' into Jellyfin database..."
            systemctl stop ${bootstrapCfg.jellyfinService}

            sleep 5

            sqlite3 "$DB" <<SQL
            BEGIN IMMEDIATE;
            INSERT INTO ApiKeys (AccessToken, Name, DateCreated, DateLastActivity)
            VALUES ('$API_KEY', '$API_KEY_NAME', datetime('now'), datetime('now'));
            COMMIT;
            SQL

            systemctl start ${bootstrapCfg.jellyfinService}
            echo "API key inserted, Jellyfin restarted"
          '';
        serviceConfig = {
          Type = "oneshot";
          User = "root";
        };
        # Don't use wantedBy multi-user.target - that causes deadlock because
        # the script runs systemctl stop/start during NixOS activation.
        # Instead, only run when jellarr.service needs it (triggered by timer).
        requiredBy = ["jellarr.service"];
        before = ["jellarr.service"];
      };
    })
  ];
}
