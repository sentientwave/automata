{ config, lib, pkgs, ... }:

let
  cfg = config.services.automata;
in {
  options.services.automata = {
    enable = lib.mkEnableOption "Automata natively running backend services";
    
    domain = lib.mkOption {
      type = lib.types.str;
      default = "automata.local";
      description = "The public domain name for Matrix Synapse and Automata.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4000;
      description = "The internal port for the Automata Phoenix application.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = "The Automata derivation to run (e.g. from beamPackages.mixRelease).";
      default = pkgs.hello; # Placeholder: User must override this with their actual package
    };

    matrixAdminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "The default Matrix admin user for Automata.";
    };

    temporalUiIp = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "The IP address to bind the Temporal UI to.";
    };
  };

  config = lib.mkIf cfg.enable {
    # 1. Native PostgreSQL with pgvector extension
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_15.withPackages (p: [ p.pgvector ]);
      ensureDatabases = [ "automata" "matrix-synapse" ];
      ensureUsers = [
        { name = "automata"; ensureDBOwnership = true; }
        { name = "matrix-synapse"; ensureDBOwnership = true; }
      ];
      authentication = pkgs.lib.mkOverride 10 ''
        # TYPE  DATABASE        USER            ADDRESS                 METHOD
        local   all             all                                     trust
        host    all             all             127.0.0.1/32            trust
        host    all             all             ::1/128                 trust
      '';
    };

    # 2. Native Matrix Synapse (sharing local Postgres)
    services.matrix-synapse = {
      enable = true;
      settings = {
        server_name = cfg.domain;
        database = {
          name = "psycopg2";
          args = {
            user = "matrix-synapse";
            database = "matrix-synapse";
            host = "/run/postgresql";
          };
        };
      };
    };

    # 3. Native Temporal Server (All-in-one Dev Server)
    systemd.services.temporal-dev = {
      description = "Temporal Development Server";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.temporal-cli}/bin/temporal server start-dev --ip 0.0.0.0 --ui-ip ${cfg.temporalUiIp}";
        Restart = "always";
        DynamicUser = true;
      };
    };

    # 4. Native Automata Phoenix Service
    systemd.services.automata = {
      description = "Automata Phoenix Application";
      after = [ "postgresql.service" "temporal-dev.service" "matrix-synapse.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        PORT = toString cfg.port;
        PHX_HOST = cfg.domain;
        DATABASE_URL = "ecto://automata@localhost/automata";
        # Standard configs for the backend logic
        MATRIX_ADMIN_USER = cfg.matrixAdminUser;
      };
      serviceConfig = {
        # Using the provided package. 
        # For actual use, the user must set `services.automata.package` in their flake.
        ExecStart = "${cfg.package}/bin/automata start"; 
        Restart = "always";
        # We assign the service to run as the automata user created by postgresql's ensureUsers
        User = "automata";
      };
    };
  };
}
