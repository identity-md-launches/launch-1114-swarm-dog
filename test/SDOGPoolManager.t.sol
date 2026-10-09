// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SDOGToken} from "../src/SDOGToken.sol";
import {SDOGTestBase} from "./helpers/SDOGTestBase.sol";
import {SDOGPairFixture, SDOGV4Actor} from "./helpers/SDOGV4Fixture.sol";
import {PoolManager} from "./vendor/v4-core/src/PoolManager.sol";
import {IPoolManager} from "./vendor/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "./vendor/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "./vendor/v4-core/src/types/PoolKey.sol";
import {Currency} from "./vendor/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "./vendor/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "./vendor/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "./vendor/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "./vendor/v4-core/src/libraries/StateLibrary.sol";

abstract contract SDOGPoolManagerTestBase is SDOGTestBase {
    using StateLibrary for IPoolManager;

    uint160 internal constant PROVENANCE_PRICE = 125270724187523965593206900;
    uint256 internal constant Q96 = 1 << 96;
    IPoolManager internal manager;
    SDOGPairFixture internal pair;
    SDOGV4Actor internal factory;
    SDOGV4Actor internal trader;
    SDOGToken internal token;
    PoolKey internal key;
    bool internal tokenIs0;
    uint256 internal seeded;

    function _launch(bool tokenIs0_) internal {
        tokenIs0 = tokenIs0_;
        vm.chainId(1);
        // Run constructor code at the specified address: PoolManager's NoDelegateCall immutable
        // must be built there, not copied from a manager deployed at another address.
        vm.etch(POOL_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool built, bytes memory runtime) = POOL_MANAGER.call("");
        assertTrue(built && runtime.length > 0, "local PoolManager construction failed");
        vm.etch(POOL_MANAGER, runtime);
        manager = IPoolManager(POOL_MANAGER);
        vm.etch(PAIRED, address(new SDOGPairFixture()).code);
        pair = SDOGPairFixture(PAIRED);
        factory = new SDOGV4Actor(manager);
        trader = new SDOGV4Actor(manager);

        // Exercise both real currency orderings without changing either chain address.
        bytes32 codeHash = keccak256(type(SDOGToken).creationCode);
        for (uint256 i; i < 256; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, codeHash)))));
            if ((predicted < PAIRED) == tokenIs0) {
                token = factory.deploy(salt);
                break;
            }
        }
        assertTrue(address(token) != address(0), "currency-order salt search failed");
        assertEq(token.balanceOf(address(factory)), SUPPLY, "factory receives entire supply before distribution");
        factory.send(token, DISTRIBUTOR, SUPPLY / 10);
        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(token) : PAIRED),
            currency1: Currency.wrap(tokenIs0 ? PAIRED : address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        // 2500 paired tokens / 1e9 SDOG = 1 / 400000. Derive the price from the economics
        // in the deployed currency order; the manifest's fixed price is provenance only.
        uint256 ratioX192 = tokenIs0 ? (uint256(1) << 192) / 400_000 : (uint256(1) << 192) * 400_000;
        uint160 price = uint160(_sqrt(ratioX192));
        if (tokenIs0) assertEq(price, PROVENANCE_PRICE, "economics-derived price must match provenance");
        int24 tick = manager.initialize(key, price);
        int24 floorTick = tick / 60 * 60;
        if (tick < 0 && tick % 60 != 0) floorTick -= 60;
        int24 lower = tokenIs0 ? floorTick + 60 : floorTick - 6000;
        int24 upper = tokenIs0 ? lower + 6000 : floorTick;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        uint256 budget = SUPPLY * 9000 / 10_000;
        uint256 liquidity = tokenIs0
            ? FullMath.mulDiv(budget, FullMath.mulDiv(sqrtLower, sqrtUpper, Q96), sqrtUpper - sqrtLower)
            : FullMath.mulDiv(budget, Q96, sqrtUpper - sqrtLower);
        assertTrue(liquidity > 0 && liquidity <= type(uint128).max, "liquidity must fit uint128");
        BalanceDelta delta = factory.seed(key, lower, upper, uint128(liquidity));
        seeded = uint256(-int256(_tokenDelta(delta)));
        assertTrue(seeded > 0 && seeded <= budget, "single-sided seed stays within ninety percent");
        assertTrue(_pairDelta(delta) == 0, "seed must not need paired currency");
        assertEq(token.balanceOf(POOL_MANAGER), seeded, "seed arrived whole at PoolManager");
        assertEq(token.balanceOf(address(factory)), budget - seeded, "only seed was debited");
        factory.send(token, REMAINDER_TO, budget - seeded);
        pair.mint(address(trader), 100 ether);
    }

    function test_LaunchSeedClaimAndRemainderConserveSupply() public {
        assertEq(token.balanceOf(address(factory)), 0, "factory forwarded the rounding remainder");
        assertEq(token.balanceOf(DISTRIBUTOR), SUPPLY / 10, "full swarm allocation");
        assertEq(token.balanceOf(REMAINDER_TO), SUPPLY * 9 / 10 - seeded, "remainder recipient");
        assertEq(pair.balanceOf(POOL_MANAGER), 0, "single-sided seed requires no IMD");
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(ALICE, SUPPLY / 10), "claim transfer");
        assertEq(token.balanceOf(ALICE), SUPPLY / 10, "claim arrives whole");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "distributor holds no fee");
        assertEq(
            token.balanceOf(ALICE) + token.balanceOf(POOL_MANAGER) + token.balanceOf(REMAINDER_TO),
            SUPPLY,
            "launch conservation"
        );
        assertEq(token.totalSupply(), SUPPLY, "launch cannot change supply");
    }

    function test_BuyAndSellThroughFeeChargingPoolManager() public {
        _roundTrip(0.01 ether);
    }

    function testFuzz_BuyAndSellSettleExactly(uint256 input) public {
        input = 1e12 + bounded(input, 1 ether - 1e12);
        _roundTrip(input);
    }

    function test_ExactOutputBuyDeliversEveryMinorUnit() public {
        uint256 desired = 1e18;
        uint256 pairBefore = pair.balanceOf(address(trader));
        BalanceDelta delta = trader.swap(key, !tokenIs0, int256(desired), true);
        assertTrue(_tokenDelta(delta) == int256(desired), "exact output token delta");
        assertTrue(_pairDelta(delta) < 0, "buy spends paired currency");
        assertEq(token.balanceOf(address(trader)), desired, "exact output arrives without token tax");
        assertEq(token.balanceOf(POOL_MANAGER), seeded - desired, "manager debited only output");
        assertEq(pairBefore - pair.balanceOf(address(trader)), uint256(-int256(_pairDelta(delta))), "exact buy input");
        assertEq(token.totalSupply(), SUPPLY, "exact output cannot mint or burn");
    }

    function test_UnpaidSwapRevertsAndRestoresBothCurrencies() public {
        uint256 pairBefore = pair.balanceOf(address(trader));
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        trader.swap(key, !tokenIs0, -0.01 ether, false);
        assertEq(token.balanceOf(address(trader)), 0, "unpaid trader cannot retain output");
        assertEq(token.balanceOf(POOL_MANAGER), seeded, "unpaid swap restores manager tokens");
        assertEq(pair.balanceOf(address(trader)), pairBefore, "unpaid swap preserves input");
        assertEq(pair.balanceOf(POOL_MANAGER), 0, "unpaid swap preserves manager input");
        (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore, "failed swap restores pool price");
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(key.toId());
        assertEq(fee0 + fee1, 0, "failed swap cannot accrue fees");
        _roundTrip(0.01 ether); // Revert must not leave the manager unusable.
    }

    function test_UnfundedSellerCannotSettleAndRetainOutput() public {
        // Establish paired-currency reserves first, then sell one SDOG from an empty account.
        trader.swap(key, !tokenIs0, -0.01 ether, true);
        SDOGV4Actor emptySeller = new SDOGV4Actor(manager);
        uint256 tokenBefore = token.balanceOf(POOL_MANAGER);
        uint256 pairBefore = pair.balanceOf(POOL_MANAGER);
        vm.expectRevert(
            abi.encodeWithSelector(SDOGToken.ERC20InsufficientBalance.selector, address(emptySeller), 0, 1e18)
        );
        emptySeller.swap(key, tokenIs0, -1e18, true);
        assertEq(token.balanceOf(POOL_MANAGER), tokenBefore, "failed sell restores SDOG reserve");
        assertEq(pair.balanceOf(POOL_MANAGER), pairBefore, "failed sell restores paired reserve");
        assertEq(token.balanceOf(address(emptySeller)), 0, "seller cannot create SDOG");
        assertEq(pair.balanceOf(address(emptySeller)), 0, "seller cannot retain output taken before settlement");
        assertEq(token.totalSupply(), SUPPLY, "failed sell cannot change supply");
    }

    function _roundTrip(uint256 input) internal {
        uint256 pairBefore = pair.balanceOf(address(trader));
        BalanceDelta buy = trader.swap(key, !tokenIs0, -int256(input), true);
        assertTrue(_pairDelta(buy) == -int256(input), "buy consumes requested exact input");
        assertTrue(_tokenDelta(buy) > 0, "buy must produce tokens");
        uint256 bought = uint256(int256(_tokenDelta(buy)));
        assertEq(token.balanceOf(address(trader)), bought, "buy output arrives whole");
        assertEq(token.balanceOf(POOL_MANAGER), seeded - bought, "buy debits manager exactly");
        assertEq(pair.balanceOf(address(trader)), pairBefore - input, "buy debits trader exactly");
        assertEq(pair.balanceOf(POOL_MANAGER), input, "buy input arrives whole");
        BalanceDelta sell = trader.swap(key, tokenIs0, -int256(bought), true);
        assertTrue(_tokenDelta(sell) == -int256(bought), "all purchased SDOG can be sold");
        assertTrue(_pairDelta(sell) > 0, "sell must produce paired currency");
        uint256 returned = uint256(int256(_pairDelta(sell)));
        assertTrue(returned < input, "round trip pays the pool's 3000 fee");
        assertEq(token.balanceOf(address(trader)), 0, "no unsellable dust or transfer limit");
        assertEq(token.balanceOf(POOL_MANAGER), seeded, "all SDOG returned without transfer tax");
        assertEq(pair.balanceOf(address(trader)), pairBefore - input + returned, "sell output arrives whole");
        assertEq(pair.balanceOf(POOL_MANAGER), input - returned, "paired currency is conserved");
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(key.toId());
        assertTrue(fee0 > 0 && fee1 > 0, "both swap directions accrue actual LP fees");
        assertEq(token.totalSupply(), SUPPLY, "fee-bearing swaps cannot change SDOG supply");
    }

    function _tokenDelta(BalanceDelta delta) internal view returns (int128) {
        return tokenIs0 ? delta.amount0() : delta.amount1();
    }

    function _pairDelta(BalanceDelta delta) internal view returns (int128) {
        return tokenIs0 ? delta.amount1() : delta.amount0();
    }

    function _sqrt(uint256 value) private pure returns (uint256 result) {
        if (value == 0) return 0;
        result = value;
        uint256 next = value / 2 + 1;
        while (next < result) {
            result = next;
            next = (value / next + next) / 2;
        }
    }
}

contract SDOGCurrency0PoolTest is SDOGPoolManagerTestBase {
    function setUp() public {
        _launch(true);
    }
}

contract SDOGCurrency1PoolTest is SDOGPoolManagerTestBase {
    function setUp() public {
        _launch(false);
    }
}
