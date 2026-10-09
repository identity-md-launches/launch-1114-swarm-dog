// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Only the Foundry cheatcodes used by this suite; no external test framework is required.
interface SDOGVm {
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function expectRevert(bytes calldata reason) external;
    function expectRevert(bytes4 selector) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data) external;
    function etch(address target, bytes calldata code) external;
    function deal(address target, uint256 balance) external;
    function warp(uint256 timestamp) external;
    function roll(uint256 blockNumber) external;
    function chainId(uint256 chainId_) external;
}

abstract contract SDOGTestBase {
    SDOGVm internal constant vm = SDOGVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);
    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant PAIRED = address(bytes20(hex"d34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7"));
    address internal constant REMAINDER_TO = address(0xdead);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function assertEq(uint256 actual, uint256 expected, string memory reason) internal pure {
        require(actual == expected, reason);
    }

    function assertTrue(bool value, string memory reason) internal pure {
        require(value, reason);
    }

    function assertFalse(bool value, string memory reason) internal pure {
        require(!value, reason);
    }

    function assertText(string memory actual, string memory expected, string memory reason) internal pure {
        require(keccak256(bytes(actual)) == keccak256(bytes(expected)), reason);
    }

    function bounded(uint256 value, uint256 maximum) internal pure returns (uint256) {
        return maximum == type(uint256).max ? value : value % (maximum + 1);
    }
}
