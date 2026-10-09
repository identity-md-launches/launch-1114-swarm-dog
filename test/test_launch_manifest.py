"""Read-only checks for the launch brief. Run after forge build; Python stdlib only."""

import json
from pathlib import Path
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LaunchManifestTest(unittest.TestCase):
    def setUp(self):
        self.launch = json.loads((ROOT / "launch.json").read_text())

    def test_exact_manifest_shape_and_token(self):
        self.assertEqual(
            set(self.launch),
            {"kind", "token", "contracts", "pool", "economics", "notes"},
        )
        self.assertEqual(self.launch["kind"], "custom_token")
        self.assertEqual(self.launch["contracts"], [])
        self.assertIsInstance(self.launch["notes"], str)
        self.assertEqual(
            self.launch["token"],
            {
                "contract": "SDOGToken",
                "name": "Swarm dog",
                "symbol": "SDOG",
                "decimals": 18,
                "constructorArgs": [],
                "totalSupply": "1000000000000000000000000000",
            },
        )

    def test_exact_pool_and_economics(self):
        self.assertEqual(
            self.launch["pool"],
            {
                "pairedCurrency": "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
                "fee": 3000,
                "tickSpacing": 60,
                "initialPrice": "125270724187523965593206900",
            },
        )
        self.assertEqual(
            self.launch["economics"],
            {
                "poolBps": 9000,
                "initialMarketCapWei": "2500000000000000000000",
                "remainderTo": "0x000000000000000000000000000000000000dead",
            },
        )

    def test_required_reproducible_build_settings(self):
        config = tomllib.loads((ROOT / "foundry.toml").read_text())["profile"]["default"]
        self.assertEqual(config["src"], "src")
        self.assertEqual(config["solc"], "0.8.26")
        self.assertEqual(config["evm_version"], "cancun")
        self.assertIs(config["optimizer"], True)
        self.assertEqual(config["bytecode_hash"], "none")
        self.assertTrue((ROOT / "src" / "SDOGToken.sol").is_file())

    def test_compiled_abi_exposes_only_fixed_erc20_surface(self):
        artifact = json.loads((ROOT / "out" / "SDOGToken.sol" / "SDOGToken.json").read_text())
        abi = artifact["abi"]
        functions = {
            item["name"] + "(" + ",".join(arg["type"] for arg in item["inputs"]) + ")"
            for item in abi if item["type"] == "function"
        }
        self.assertEqual(
            functions,
            {
                "name()", "symbol()", "decimals()", "totalSupply()",
                "balanceOf(address)", "allowance(address,address)",
                "transfer(address,uint256)", "approve(address,uint256)",
                "transferFrom(address,address,uint256)",
            },
        )
        constructors = [item for item in abi if item["type"] == "constructor"]
        self.assertEqual(len(constructors), 1)
        self.assertEqual(constructors[0]["inputs"], [])
        self.assertEqual(constructors[0]["stateMutability"], "nonpayable")
        self.assertFalse(any(item["type"] in {"fallback", "receive"} for item in abi))


if __name__ == "__main__":
    unittest.main(verbosity=2)
