{ config, pkgs, ... }:

{
  system.stateVersion = "25.05";

  networking.hostName = "sentientwave-community";
  networking.firewall.allowedTCPPorts = [ 22 80 443 4000 5432 7233 8080 ];

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16;
    ensureDatabases = [ "sentientwave_dev" ];
    authentication = ''
      local all all trust
    '';
  };

  virtualisation.oci-containers.backend = "podman";

  virtualisation.oci-containers.containers.sentientwave = {
    image = "ghcr.io/sentientwave/automata:latest";
    ports = [ "4000:4000" ];
    environment = {
      MIX_ENV = "prod";
      DATABASE_URL = "ecto://postgres:postgres@127.0.0.1/sentientwave_dev";
    };
    autoStart = true;
  };
}
