// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SDOGToken} from "../src/SDOGToken.sol";
import {SDOGTestBase} from "./helpers/SDOGTestBase.sol";

contract SDOGDeploymentCaller {
    function deploy() external returns (SDOGToken) {
        return new SDOGToken();
    }
}

contract SDOGBehaviorTest is SDOGTestBase {
    SDOGToken internal token;

    function setUp() public {
        token = new SDOGToken();
    }

    function test_ConstructorMintsOnceToImmediateDeployerAndEmitsTransfer() public {
        SDOGDeploymentCaller factory = new SDOGDeploymentCaller();
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(factory), SUPPLY);
        vm.prank(ALICE);
        SDOGToken launched = factory.deploy();
        assertText(launched.name(), "Swarm dog", "name");
        assertText(launched.symbol(), "SDOG", "symbol");
        assertEq(launched.decimals(), 18, "decimals");
        assertEq(launched.totalSupply(), SUPPLY, "supply");
        assertEq(launched.balanceOf(address(factory)), SUPPLY, "factory must receive all 1e27 units");
        assertEq(launched.balanceOf(ALICE), 0, "external caller is not the deployer");
        assertEq(launched.balanceOf(address(launched)), 0, "no token-held allocation");
        assertEq(launched.balanceOf(DISTRIBUTOR), 0, "token must not distribute the swarm allocation");
        assertEq(launched.balanceOf(POOL_MANAGER), 0, "token must not seed the pool itself");
        assertEq(launched.balanceOf(REMAINDER_TO), 0, "token must not distribute the remainder itself");
    }

    function test_LaunchTransfersAndClaimsArriveWhole() public {
        uint256 swarm = SUPPLY / 10;
        assertTrue(token.transfer(DISTRIBUTOR, swarm), "swarm transfer");
        assertTrue(token.transfer(POOL_MANAGER, SUPPLY - swarm), "pool transfer");
        assertEq(token.balanceOf(address(this)), 0, "no hidden reserved supply");
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "swarm received exactly ten percent");
        assertEq(token.balanceOf(POOL_MANAGER), SUPPLY - swarm, "pool received exactly ninety percent");
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(ALICE, swarm), "claim");
        vm.prank(ALICE);
        assertTrue(token.transfer(REMAINDER_TO, swarm), "ordinary holder has no transfer limit");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "claim empties distributor");
        assertEq(token.balanceOf(REMAINDER_TO), swarm, "dead remainder address is an ordinary holder, not a burn");
        assertEq(token.totalSupply(), SUPPLY, "launch and claim cannot burn");
    }

    function test_ZeroBalanceAccountCanTransferZeroAndEmit() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0), "zero transfer");
        assertEq(token.balanceOf(ALICE), 0, "sender unchanged");
        assertEq(token.balanceOf(BOB), 0, "receiver unchanged");
    }

    function test_ZeroTransferFromNeedsNoAllowanceAndEmits() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0), "zero delegated transfer");
        assertEq(token.allowance(ALICE, SPENDER), 0, "zero allowance unchanged");
        assertEq(token.balanceOf(BOB), 0, "zero cannot create balance");
    }

    function test_ApprovalCanBeReplacedAndRevokedWithoutABalance() public {
        vm.startPrank(ALICE);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(ALICE, SPENDER, type(uint256).max);
        assertTrue(token.approve(SPENDER, type(uint256).max), "approve maximum without funds");
        assertTrue(token.approve(SPENDER, 7), "replace approval");
        assertEq(token.allowance(ALICE, SPENDER), 7, "replacement is not additive");
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(ALICE, SPENDER, 0);
        assertTrue(token.approve(SPENDER, 0), "revoke");
        vm.stopPrank();
        token.transfer(ALICE, 7);
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.balanceOf(ALICE), 7, "revocation protects later deposits");
    }

    function test_ExactAllowanceCannotBeReused() public {
        token.approve(SPENDER, 1);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1), "spend exact allowance");
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.balanceOf(BOB), 0, "second spend failed atomically");
        assertEq(token.allowance(address(this), SPENDER), 0, "allowance exhausted");
    }

    function test_SelfTransferFromPreservesBalanceButSpendsAllowance() public {
        token.approve(SPENDER, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), address(this), SUPPLY);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), address(this), SUPPLY), "delegated self-transfer");
        assertEq(token.balanceOf(address(this)), SUPPLY, "self-transfer preserves balance");
        assertEq(token.allowance(address(this), SPENDER), 0, "self-transfer consumes finite allowance");
    }

    function test_TransferFromToSpenderReceivesExactlyTheAmount() public {
        token.approve(SPENDER, SUPPLY);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), SPENDER, SUPPLY), "spender may also be recipient");
        assertEq(token.balanceOf(SPENDER), SUPPLY, "no transfer limit or fee");
        assertEq(token.balanceOf(address(this)), 0, "deployer emptied");
    }

    function test_HolderCannotUseTransferFromWithoutItsOwnApproval() public {
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), ALICE, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY, "no implicit deployer privilege");
    }

    function test_ApprovalDoesNotAuthorizeAnotherSpender() public {
        token.approve(SPENDER, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.allowance(address(this), SPENDER), SUPPLY, "other spender approval unchanged");
        assertEq(token.balanceOf(BOB), 0, "unauthorized spender received nothing");
    }

    function test_FailedBalanceCheckRestoresFiniteAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 100);
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.allowance(ALICE, SPENDER), 100, "failure must roll back allowance decrement");
        assertEq(token.balanceOf(ALICE), 0, "sender unchanged");
        assertEq(token.balanceOf(BOB), 0, "receiver unchanged");
    }

    function test_MaximumSpendFailsWithoutOverflowOrChangingInfiniteApproval() public {
        token.approve(SPENDER, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                SDOGToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, type(uint256).max);
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max, "maximum approval unchanged");
        assertEq(token.balanceOf(address(this)), SUPPLY, "balance unchanged");
        assertEq(token.balanceOf(ALICE), 0, "receiver unchanged");
    }

    function test_TransferFromInvalidReceiverRestoresAllowanceAndBalance() public {
        token.approve(SPENDER, 11);
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 11);
        assertEq(token.allowance(address(this), SPENDER), 11, "invalid receiver must not consume allowance");
        assertEq(token.balanceOf(address(this)), SUPPLY, "invalid receiver must not burn");
        assertEq(token.balanceOf(address(0)), 0, "zero address cannot acquire tokens");
    }

    function test_ZeroAddressRejectedEvenForZeroAmounts() public {
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(ALICE, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(ALICE, 0);
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(ALICE, 0);
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        assertEq(token.totalSupply(), SUPPLY, "invalid zero operations cannot change supply");
    }

    function testFuzz_ZeroSpenderCannotBeApproved(uint256 amount) public {
        vm.expectRevert(abi.encodeWithSelector(SDOGToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        assertEq(token.allowance(address(this), address(0)), 0, "zero spender approval absent");
    }

    function testFuzz_TransferRoundTripIsExact(uint256 amount) public {
        amount = bounded(amount, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, amount);
        assertTrue(token.transfer(ALICE, amount), "send");
        assertEq(token.balanceOf(ALICE), amount, "recipient receives every minor unit");
        assertEq(token.balanceOf(address(this)), SUPPLY - amount, "sender pays only amount");
        vm.prank(ALICE);
        assertTrue(token.transfer(address(this), amount), "return");
        assertEq(token.balanceOf(address(this)), SUPPLY, "round trip is lossless");
        assertEq(token.balanceOf(ALICE), 0, "no dust withheld");
        assertEq(token.totalSupply(), SUPPLY, "fixed supply");
    }

    function testFuzz_SelfTransferCannotInflate(uint256 amount) public {
        amount = bounded(amount, SUPPLY);
        assertTrue(token.transfer(address(this), amount), "self-transfer");
        assertTrue(token.transfer(address(this), amount), "repeat self-transfer");
        assertEq(token.balanceOf(address(this)), SUPPLY, "aliased sender and receiver cannot inflate");
        assertEq(token.totalSupply(), SUPPLY, "supply unchanged");
    }

    function testFuzz_AnyNonzeroRecipientReceivesTheExactAmount(address recipient, uint256 amount) public {
        if (recipient == address(0)) recipient = ALICE;
        amount = bounded(amount, SUPPLY);
        assertTrue(token.transfer(recipient, amount), "arbitrary recipient must not be blacklisted or limited");
        if (recipient == address(this)) {
            assertEq(token.balanceOf(recipient), SUPPLY, "arbitrary self-transfer");
        } else {
            assertEq(token.balanceOf(recipient), amount, "arbitrary recipient receives every unit");
            assertEq(token.balanceOf(address(this)), SUPPLY - amount, "sender pays only amount");
        }
        assertEq(token.totalSupply(), SUPPLY, "arbitrary recipient cannot trigger a burn");
    }

    function testFuzz_TransferExceedingBalanceIsAtomic(uint256 balance, uint256 excess) public {
        balance = bounded(balance, SUPPLY);
        excess = 1 + bounded(excess, type(uint256).max - balance - 1);
        token.transfer(ALICE, balance);
        vm.expectRevert(
            abi.encodeWithSelector(SDOGToken.ERC20InsufficientBalance.selector, ALICE, balance, balance + excess)
        );
        vm.prank(ALICE);
        token.transfer(BOB, balance + excess);
        assertEq(token.balanceOf(ALICE), balance, "failed sender unchanged");
        assertEq(token.balanceOf(BOB), 0, "failed recipient unchanged");
        assertEq(token.totalSupply(), SUPPLY, "failed transfer supply unchanged");
    }

    function testFuzz_FiniteAllowanceTracksRepeatedSpending(uint256 approved, uint256 first) public {
        approved = bounded(approved, SUPPLY);
        first = bounded(first, approved);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), SPENDER, approved);
        assertTrue(token.approve(SPENDER, approved), "approve");
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, first);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, first), "partial spend");
        assertEq(token.allowance(address(this), SPENDER), approved - first, "remaining approval");
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, approved - first), "remaining spend");
        assertEq(token.allowance(address(this), SPENDER), 0, "fully consumed");
        assertEq(token.balanceOf(ALICE), approved, "exact aggregate delivery");
        assertEq(token.balanceOf(address(this)), SUPPLY - approved, "exact aggregate debit");
    }

    function testFuzz_InfiniteAllowanceSurvivesRepeatedSpending(uint256 first) public {
        first = bounded(first, SUPPLY);
        token.approve(SPENDER, type(uint256).max);
        vm.startPrank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, first), "first spend");
        assertTrue(token.transferFrom(address(this), ALICE, SUPPLY - first), "second spend");
        vm.stopPrank();
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max, "infinite approval unchanged");
        assertEq(token.balanceOf(ALICE), SUPPLY, "no maximum wallet limit");
    }

    function testFuzz_InsufficientAllowanceIsAtomic(uint256 approved) public {
        approved = bounded(approved, SUPPLY - 1);
        token.approve(SPENDER, approved);
        vm.expectRevert(
            abi.encodeWithSelector(SDOGToken.ERC20InsufficientAllowance.selector, SPENDER, approved, approved + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, approved + 1);
        assertEq(token.allowance(address(this), SPENDER), approved, "failed spend preserves approval");
        assertEq(token.balanceOf(address(this)), SUPPLY, "failed spend preserves sender");
        assertEq(token.balanceOf(ALICE), 0, "failed spend preserves recipient");
    }

    function test_NoMintBurnOwnershipAdminOrUpgradeEntryPoints() public {
        token.transfer(ALICE, 100);
        // An approval cannot grant burn/seize powers either.
        vm.prank(ALICE);
        token.approve(address(this), type(uint256).max);
        bytes[] memory calls = new bytes[](25);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", BOB, 1);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[4] = abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, 1);
        calls[5] = abi.encodeWithSignature("owner()");
        calls[6] = abi.encodeWithSignature("transferOwnership(address)", BOB);
        calls[7] = abi.encodeWithSignature("renounceOwnership()");
        calls[8] = abi.encodeWithSignature("setOwner(address)", BOB);
        calls[9] = abi.encodeWithSignature("pause()");
        calls[10] = abi.encodeWithSignature("unpause()");
        calls[11] = abi.encodeWithSignature("blacklist(address)", ALICE);
        calls[12] = abi.encodeWithSignature("freeze(address)", ALICE);
        calls[13] = abi.encodeWithSignature("setBlacklist(address,bool)", ALICE, true);
        calls[14] = abi.encodeWithSignature("seize(address)", ALICE);
        calls[15] = abi.encodeWithSignature("setFee(uint256)", 100);
        calls[16] = abi.encodeWithSignature("setTax(uint256)", 100);
        calls[17] = abi.encodeWithSignature("setMaxTxAmount(uint256)", 1);
        calls[18] = abi.encodeWithSignature("setMinter(address)", BOB);
        calls[19] = abi.encodeWithSignature("initialize(address)", BOB);
        calls[20] = abi.encodeWithSignature("upgradeTo(address)", BOB);
        calls[21] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", BOB, bytes(""));
        calls[22] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        calls[23] = abi.encodeWithSignature("grantRole(bytes32,address)", bytes32(0), BOB);
        calls[24] = abi.encodeWithSignature("setTotalSupply(uint256)", SUPPLY + 1);
        address[3] memory callers = [address(this), ALICE, BOB];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(calls[i]);
                assertFalse(ok, "forbidden entry point accepted");
                assertEq(token.totalSupply(), SUPPLY, "no inflation or burn");
                assertEq(token.balanceOf(ALICE), 100, "holder protected");
                assertEq(token.balanceOf(BOB), 0, "caller gained nothing");
            }
        }
        vm.warp(block.timestamp + 3650 days);
        vm.roll(block.number + 25_000_000);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100), "no freeze, blacklist, or expiry");
        assertEq(token.balanceOf(BOB), 100, "all units still transferable");
        assertEq(token.totalSupply(), SUPPLY, "no time-based issuance");
    }

    function test_RejectsEtherAndUnknownCalldata() public {
        vm.deal(address(this), 1 ether);
        (bool received,) = address(token).call{value: 1}("");
        assertFalse(received, "no payable receive entry point");
        (bool fallbackAccepted,) = address(token).call(hex"ffffffff");
        assertFalse(fallbackAccepted, "no fallback dispatcher");
        assertEq(address(token).balance, 0, "failed call cannot retain ETH");
    }

    function test_CreationAndRuntimeHaveNoDelegatecallCallcodeOrSelfdestruct() public view {
        _checkOpcodes(address(token).code);
        _checkOpcodes(type(SDOGToken).creationCode);
    }

    function _checkOpcodes(bytes memory code) private pure {
        assertTrue(code.length > 0, "code missing");
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f; // PUSH data are not executable opcodes.
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
        }
    }
}
