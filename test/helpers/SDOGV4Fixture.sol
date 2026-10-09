// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SDOGToken} from "../../src/SDOGToken.sol";
import {IPoolManager} from "../vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../vendor/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "../vendor/v4-core/src/types/PoolKey.sol";
import {Currency} from "../vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "../vendor/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "../vendor/v4-core/src/libraries/TickMath.sol";

interface SDOGFixtureERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev An 18-decimal paired-currency stand-in. Only the local test controller can fund traders.
contract SDOGPairFixture {
    address private immutable controller = msg.sender;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint8 public constant decimals = 18;

    function mint(address to, uint256 amount) external {
        require(msg.sender == controller, "test controller only");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(to != address(0), "zero recipient");
        require(balanceOf[msg.sender] >= amount, "pair balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Local launch/trader driver, using v4's actual unlock/sync/settle/take flow.
/// This fixture is not an implementation of ProjectFactory or a Merkle distributor.
contract SDOGV4Actor is IUnlockCallback {
    IPoolManager private immutable manager;
    address private immutable controller = msg.sender;

    modifier onlyController() {
        require(msg.sender == controller, "test controller only");
        _;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function deploy(bytes32 salt) external onlyController returns (SDOGToken) {
        return new SDOGToken{salt: salt}();
    }

    function send(SDOGToken token, address to, uint256 amount) external onlyController {
        require(token.transfer(to, amount), "token transfer failed");
    }

    function seed(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity)
        external
        onlyController
        returns (BalanceDelta)
    {
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0));
        return abi.decode(manager.unlock(abi.encode(true, key, abi.encode(params), true)), (BalanceDelta));
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, bool payDebts)
        external
        onlyController
        returns (BalanceDelta)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(zeroForOne, amountSpecified, limit);
        return abi.decode(manager.unlock(abi.encode(false, key, abi.encode(params), payDebts)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "pool manager only");
        (bool isSeed, PoolKey memory key, bytes memory params, bool payDebts) =
            abi.decode(data, (bool, PoolKey, bytes, bool));
        BalanceDelta delta;
        if (isSeed) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(params, (IPoolManager.ModifyLiquidityParams)), "");
        } else {
            delta = manager.swap(key, abi.decode(params, (IPoolManager.SwapParams)), "");
        }
        _settle(key.currency0, delta.amount0(), payDebts);
        _settle(key.currency1, delta.amount1(), payDebts);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, bool payDebts) private {
        if (delta < 0 && payDebts) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            require(SDOGFixtureERC20(Currency.unwrap(currency)).transfer(address(manager), amount), "payment failed");
            require(manager.settle() == amount, "settlement must receive the exact input");
        } else if (delta > 0) {
            uint256 amount = uint256(int256(delta));
            uint256 beforeBalance = SDOGFixtureERC20(Currency.unwrap(currency)).balanceOf(address(this));
            manager.take(currency, address(this), amount);
            require(
                SDOGFixtureERC20(Currency.unwrap(currency)).balanceOf(address(this)) == beforeBalance + amount,
                "take must deliver the exact output"
            );
        }
    }
}
