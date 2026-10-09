// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SDOGToken} from "../src/SDOGToken.sol";
import {SDOGTestBase} from "./helpers/SDOGTestBase.sol";

/// @dev Every balance originates in the constructor. No deal/storage writes fabricate token funds.
contract SDOGHandler is SDOGTestBase {
    SDOGToken public immutable token;
    address[7] public actors;
    mapping(address => uint256) public modelBalance;
    mapping(address => mapping(address => uint256)) public modelAllowance;

    constructor() {
        token = new SDOGToken();
        actors = [address(this), ALICE, BOB, SPENDER, POOL_MANAGER, DISTRIBUTOR, REMAINDER_TO];
        modelBalance[address(this)] = SUPPLY;
        // Start with funded holders and a mix of finite/unlimited approvals so random spends
        // exercise real value movements from the first sequence, not just zero-value calls.
        uint256 share = SUPPLY / actors.length;
        for (uint256 i = 1; i < actors.length; ++i) {
            assertTrue(token.transfer(actors[i], share), "initial distribution");
            modelBalance[address(this)] -= share;
            modelBalance[actors[i]] = share;
        }
        for (uint256 i; i < actors.length; ++i) {
            address spender = actors[(i + 1) % actors.length];
            uint256 approved = i % 2 == 0 ? type(uint256).max : share;
            vm.prank(actors[i]);
            assertTrue(token.approve(spender, approved), "initial approval");
            modelAllowance[actors[i]][spender] = approved;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bounded(amount, modelBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "valid transfer returned false");
        modelBalance[from] -= amount;
        modelBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = infinite ? type(uint256).max : bounded(amount, SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approval returned false");
        modelAllowance[owner][spender] = amount;
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, 0), "revoke returned false");
        modelAllowance[owner][spender] = 0;
    }

    function spend(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowance_ = modelAllowance[from][spender];
        uint256 available = modelBalance[from] < allowance_ ? modelBalance[from] : allowance_;
        amount = bounded(amount, available);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount), "valid delegated transfer returned false");
        modelBalance[from] -= amount;
        modelBalance[to] += amount;
        if (allowance_ != type(uint256).max) modelAllowance[from][spender] -= amount;
    }

    function attemptOverspend(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowance_ = modelAllowance[from][spender];
        uint256 available = modelBalance[from];
        // Exceed whichever authorization constraint is tighter, including empty and self accounts.
        uint256 amount = (available < allowance_ ? available : allowance_) + 1;
        bytes memory reason = allowance_ < amount
            ? abi.encodeWithSelector(SDOGToken.ERC20InsufficientAllowance.selector, spender, allowance_, amount)
            : abi.encodeWithSelector(SDOGToken.ERC20InsufficientBalance.selector, from, available, amount);
        vm.expectRevert(reason);
        vm.prank(spender);
        token.transferFrom(from, to, amount);
        // The model is deliberately unchanged: the invariant checks atomic rollback of all state.
    }

    function attemptInvalidTransfer(uint256 fromSeed, uint256 toSeed, bool zeroRecipient) external {
        address from = actors[fromSeed % actors.length];
        address to = zeroRecipient ? address(0) : actors[toSeed % actors.length];
        uint256 amount = zeroRecipient ? modelBalance[from] : modelBalance[from] + 1;
        bytes memory reason = zeroRecipient
            ? abi.encodeWithSelector(SDOGToken.ERC20InvalidReceiver.selector, address(0))
            : abi.encodeWithSelector(SDOGToken.ERC20InsufficientBalance.selector, from, modelBalance[from], amount);
        vm.expectRevert(reason);
        vm.prank(from);
        token.transfer(to, amount);
    }
}

contract SDOGInvariantTest is SDOGTestBase {
    SDOGHandler internal handler;
    SDOGToken internal token;

    // This is the same public targeting interface consumed by Foundry's StdInvariant.
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    function setUp() public {
        handler = new SDOGHandler();
        token = handler.token();
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() public view returns (FuzzSelector[] memory targets) {
        targets = new FuzzSelector[](1);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = SDOGHandler.transfer.selector;
        selectors[1] = SDOGHandler.approve.selector;
        selectors[2] = SDOGHandler.revoke.selector;
        selectors[3] = SDOGHandler.spend.selector;
        selectors[4] = SDOGHandler.attemptOverspend.selector;
        selectors[5] = SDOGHandler.attemptInvalidTransfer.selector;
        targets[0] = FuzzSelector(address(handler), selectors);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_SupplyBalancesAndAllowancesMatchModel() public view {
        uint256 sum;
        for (uint256 i; i < 7; ++i) {
            address owner = handler.actors(i);
            uint256 balance = token.balanceOf(owner);
            sum += balance;
            assertEq(balance, handler.modelBalance(owner), "balance diverged from authorized movements");
            for (uint256 j; j < 7; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.modelAllowance(owner, spender),
                    "approval diverged from authorized spending"
                );
            }
        }
        assertEq(token.totalSupply(), SUPPLY, "supply must be fixed forever");
        assertEq(sum, SUPPLY, "every constructor-minted unit is conserved");
        assertEq(token.balanceOf(address(0)), 0, "no burns to zero");
        assertEq(token.balanceOf(address(token)), 0, "no hidden token tax balance");
    }

    function afterInvariant() public {
        // Regardless of prior approvals and failures, every holder can still move its whole balance.
        address recipient = handler.actors(0);
        for (uint256 i = 1; i < 7; ++i) {
            address holder = handler.actors(i);
            uint256 balance = token.balanceOf(holder);
            vm.prank(holder);
            assertTrue(token.transfer(recipient, balance), "holder became unable to exit");
            assertEq(token.balanceOf(holder), 0, "full transfer left a fee or locked balance");
        }
        assertEq(token.balanceOf(recipient), SUPPLY, "all holders can reconsolidate the full supply");
    }
}
