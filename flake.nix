{
  description = "Marlowe Cardano implementation";

  inputs = {
    cardano-world.url = "github:input-output-hk/cardano-world/d22f50fc77d23e2612ca2b313a098dd0b48834d4";
    std.url = "github:divnix/std";
    iogx.url = "github:input-output-hk/iogx?ref=fs-based-interface";
    n2c.url = "github:nlewo/nix2container";
    bitte-cells.url = "github:input-output-hk/bitte-cells";
  };

  outputs = inputs: inputs.iogx.lib.mkFlake inputs ./.;

  nixConfig = {
    extra-substituters = [
      "https://ci.iog.io"
      "https://cache.iog.io"
      "https://cache.zw3rk.com"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk="
    ];
    allow-import-from-derivation = "true";
  };
}
