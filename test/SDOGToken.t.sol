// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SDOGToken} from "../src/SDOGToken.sol";

/// @dev Local caller for exercising transfers from a distinct account without dependencies.
contract TokenHolder {
    function send(SDOGToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function spend(SDOGToken token, address from, address to, uint256 amount) external returns (bool) {
        return token.transferFrom(from, to, amount);
    }
}

contract SDOGTokenTest {
    SDOGToken private token;
    TokenHolder private holder;
    uint256 private constant SUPPLY = 1e27;

    function setUp() public {
        token = new SDOGToken();
        holder = new TokenHolder();
    }

    function testDeploymentMintsEntireFixedSupplyToDeployer() public view {
        require(keccak256(bytes(token.name())) == keccak256("Swarm dog"), "name");
        require(keccak256(bytes(token.symbol())) == keccak256("SDOG"), "symbol");
        require(token.decimals() == 18, "decimals");
        require(token.totalSupply() == SUPPLY, "supply");
        require(token.balanceOf(address(this)) == SUPPLY, "full deployer balance");
        require(token.balanceOf(address(token)) == 0, "no retained allocation");
    }

    function testTransfersRoundTripWithoutFeesIncludingZeroAndSelf() public {
        require(token.transfer(address(holder), SUPPLY), "transfer");
        require(token.balanceOf(address(this)) == 0, "sender debited");
        require(token.balanceOf(address(holder)) == SUPPLY, "recipient received all");
        require(holder.send(token, address(holder), SUPPLY), "self transfer");
        require(holder.send(token, address(this), 0), "zero transfer");
        require(holder.send(token, address(this), SUPPLY), "return transfer");
        require(token.balanceOf(address(this)) == SUPPLY, "round trip preserves balance");
        require(token.balanceOf(address(holder)) == 0, "holder empty");
        require(token.totalSupply() == SUPPLY, "fixed supply");
    }

    function testApprovedSpendingConsumesAllowanceAndCannotOverspend() public {
        require(token.approve(address(holder), 100e18), "approve");
        require(holder.spend(token, address(this), address(holder), 100e18), "spend");
        require(token.allowance(address(this), address(holder)) == 0, "allowance consumed");
        (bool ok, bytes memory reason) =
            address(holder).call(abi.encodeCall(TokenHolder.spend, (token, address(this), address(holder), 1)));
        require(!ok, "unapproved spend succeeded");
        require(
            keccak256(reason)
                == keccak256(
                    abi.encodeWithSelector(SDOGToken.ERC20InsufficientAllowance.selector, address(holder), 0, 1)
                ),
            "allowance error"
        );
        require(token.balanceOf(address(holder)) == 100e18, "failed spend changed recipient");
        require(token.balanceOf(address(this)) == SUPPLY - 100e18, "failed spend changed sender");
    }

    function testUnlimitedAllowanceRemainsUnchanged() public {
        require(token.approve(address(holder), type(uint256).max), "approve");
        require(holder.spend(token, address(this), address(holder), 1e18), "spend");
        require(token.allowance(address(this), address(holder)) == type(uint256).max, "infinite allowance");
        require(token.balanceOf(address(holder)) == 1e18, "received amount");
    }

    function testTransferExceedingBalanceRevertsWithoutChangingBalances() public {
        (bool ok, bytes memory reason) =
            address(token).call(abi.encodeCall(SDOGToken.transfer, (address(holder), SUPPLY + 1)));
        require(!ok, "oversized transfer succeeded");
        require(
            keccak256(reason)
                == keccak256(
                    abi.encodeWithSelector(
                        SDOGToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1
                    )
                ),
            "balance error"
        );
        require(token.balanceOf(address(this)) == SUPPLY, "sender unchanged");
        require(token.balanceOf(address(holder)) == 0, "recipient unchanged");
    }

    function testTransferToZeroRevertsWithoutBurning() public {
        (bool ok, bytes memory reason) = address(token).call(abi.encodeCall(SDOGToken.transfer, (address(0), 1)));
        require(!ok, "zero recipient accepted");
        require(
            keccak256(reason) == keccak256(abi.encodeWithSelector(SDOGToken.ERC20InvalidReceiver.selector, address(0))),
            "receiver error"
        );
        require(token.balanceOf(address(this)) == SUPPLY, "sender unchanged");
        require(token.totalSupply() == SUPPLY, "no burn");
    }
}
