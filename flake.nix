{
  description = "Aftok Helm chart and deployment library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        chartLib = import ./lib.nix { inherit pkgs; };
      in
      {
        lib = chartLib;

        devShells.default = pkgs.mkShell {
          buildInputs = chartLib.k8sToolDeps ++ chartLib.genericScripts;
          shellHook = chartLib.defaultShellHook;
        };
      });
}
