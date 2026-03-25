{
  description = "Automata NixOS Deployment Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }: 
    let
      # Export the NixOS module for arbitrary configurations
      nixosModule = import ./module.nix;
    in
    {
      nixosModules.default = nixosModule;
      nixosModules.automata = nixosModule;
    };
}
