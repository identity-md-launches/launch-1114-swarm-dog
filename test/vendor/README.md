# Offline test dependencies

Only the source dependency closure of PoolManager and StateLibrary is included.
These are ordinary files, with no submodules or network requirement at test time.

- Uniswap v4-core v4.0.0: https://github.com/Uniswap/v4-core/tree/e50237c43811bd9b526eff40f26772152a42daba
- Solmate (the v4-core submodule revision): https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647

The only source change is the Owned import in v4-core/src/ProtocolFees.sol,
rewritten to a relative path so the repository needs no remappings. Licenses are
included beside the sources. These dependencies are test fixtures only.
