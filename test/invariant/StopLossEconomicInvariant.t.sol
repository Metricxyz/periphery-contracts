// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
// forge-lint: disable-start(unsafe-typecast)

// Stop-loss economic invariant for OracleValueStopLossExtension.
// The true price stays constant; the oracle quote is moved around it (stale or wrong). OracleValueStopLossExtension
// (drawdown dd, no decay) should stop any trading that takes a seeded bin's per-share value more than dd below its
// high watermark. So a passive LP whose bins were all seeded at the true price must never lose more than about dd
// of its value measured at the TRUE price, however the attacker sequences oracle moves, swaps and liquidity.
// Config by env: SL_DD_E6 (drawdown, default 20000 = 2%), SL_MOVE_E6 (max oracle deviation, default 80000 = 8%),
// SL_BINS, SL_BINLEN, SL_HALFSPREAD_E6.

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockPriceProvider} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {FactoryFeeCapsStub} from "@metric-core-test/FactoryFeeCapsStub.sol";
import {PoolInitPreprocessor} from "@metric-core-test/PoolInitPreprocessor.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "@metric-core/MetricOmmPoolDeployer.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {PoolStateLibrary} from "@metric-core/libraries/PoolStateLibrary.sol";
import {MockERC20} from "@metric-core-test/mocks/MockERC20.sol";
import {TestCaller} from "@metric-core-test/mocks/TestCaller.sol";
import {OracleValueStopLossExtension} from "../../contracts/extensions/OracleValueStopLossExtension.sol";
import {IOracleValueStopLossExtension} from "../../contracts/interfaces/extensions/IOracleValueStopLossExtension.sol";

contract SLHandler is CommonBase, StdUtils {
  MetricOmmPool public pool;
  MockPriceProvider public oracle;
  MockERC20 public t0;
  MockERC20 public t1;
  TestCaller public atk;
  address public atkEOA;
  int16 public lo;
  int16 public hi;
  uint256 public midTrue;
  uint256 public halfSpreadE6;
  uint256 public maxMoveE6;

  uint256 public nSwapOk;
  uint256 public nStopped;
  uint256 public nMoves;
  int256 public lastDevE6;

  bytes4 internal constant SL_SEL = IOracleValueStopLossExtension.OracleStopLossTriggered.selector;

  constructor(
    MetricOmmPool pool_,
    MockPriceProvider o,
    MockERC20 a,
    MockERC20 b,
    TestCaller atk_,
    address eoa,
    int16 lo_,
    int16 hi_,
    uint256 mid,
    uint256 hs,
    uint256 mv
  ) {
    (pool, oracle, t0, t1, atk, atkEOA, lo, hi) = (pool_, o, a, b, atk_, eoa, lo_, hi_);
    (midTrue, halfSpreadE6, maxMoveE6) = (mid, hs, mv);
  }

  /// moves the oracle mid to midTrue * (1 + dev), |dev| <= maxMove; the true price does not move
  function moveOracle(uint256 seed) external {
    int256 dev = int256(bound(seed, 0, 2 * maxMoveE6)) - int256(maxMoveE6);
    if (seed % 4 == 0) dev = 0; // often return to the truth
    uint256 m = Math.mulDiv(midTrue, uint256(int256(1e6) + dev), 1e6);
    oracle.setBidAndAskPrice(
      uint128(Math.mulDiv(m, 1e6 - halfSpreadE6, 1e6)), uint128(Math.mulDiv(m, 1e6 + halfSpreadE6, 1e6))
    );
    lastDevE6 = dev;
    nMoves++;
  }

  function swap(bool zeroForOne, bool exactOut, uint256 amtSeed) external {
    MockERC20 tok = exactOut ? (zeroForOne ? t1 : t0) : (zeroForOne ? t0 : t1);
    uint256 bal = tok.balanceOf(address(atk));
    uint256 amt = amtSeed % 3 == 0 ? bound(amtSeed >> 8, 1, 1e18) : bound(amtSeed >> 8, 1, bal < 30_000e18 ? bal : 30_000e18);
    int128 spec = exactOut ? -int128(int256(amt)) : int128(int256(amt));
    vm.prank(atkEOA);
    try atk.swap(address(pool), address(atk), zeroForOne, spec, zeroForOne ? 0 : type(uint128).max) {
      nSwapOk++;
    } catch (bytes memory r) {
      if (bytes4(r) == SL_SEL) nStopped++;
    }
  }

  function addLiq(uint256 binSeed, uint256 sharesSeed) external {
    int16 a = int16(int256(lo) + int256(bound(binSeed, 0, uint256(int256(hi) - int256(lo)))));
    int256[] memory idx = new int256[](1);
    uint256[] memory sh = new uint256[](1);
    idx[0] = a;
    sh[0] = bound(sharesSeed, 1e6, 5e19);
    vm.prank(atkEOA);
    try atk.addLiquidity(address(pool), 0, LiquidityDelta({binIdxs: idx, shares: sh})) {} catch {}
  }

  function removeLiq(uint256 binSeed, uint256 fracSeed) external {
    int16 a = int16(int256(lo) + int256(bound(binSeed, 0, uint256(int256(hi) - int256(lo)))));
    uint256 have = PoolStateLibrary._positionBinShares(address(pool), address(atk), 0, a);
    if (have == 0) return;
    int256[] memory idx = new int256[](1);
    uint256[] memory sh = new uint256[](1);
    idx[0] = a;
    sh[0] = fracSeed % 2 == 0 ? have : bound(fracSeed, 1, have);
    vm.prank(atkEOA);
    try atk.removeLiquidity(address(pool), 0, LiquidityDelta({binIdxs: idx, shares: sh})) {} catch {}
  }
}

contract StopLossInvariantTest is Test, FactoryFeeCapsStub, PoolInitPreprocessor {
  MetricOmmPoolDeployer internal deployer;
  OracleValueStopLossExtension internal ext;
  MetricOmmPool internal p;
  MockPriceProvider internal o;
  MockERC20 internal a0;
  MockERC20 internal a1;
  TestCaller internal atkC;
  TestCaller internal lpC;
  TestCaller internal keeperC;
  address internal atkU;
  address internal lpU;
  address internal keeperU;
  SLHandler internal h;
  int16 internal LO;
  int16 internal HI;
  uint256 internal midTrue;
  uint256 internal dd;
  uint256 internal lpStart;
  uint256 internal worstLossE6;

  function _env(string memory k, uint256 d) internal view returns (uint256) {
    return vm.envOr(k, d);
  }

  function _deploy() internal {
    uint256 bins = _env("SL_BINS", 10);
    uint16 len = uint16(_env("SL_BINLEN", 1000));
    BinState[] memory nn = new BinState[](bins);
    BinState[] memory ng = new BinState[](bins);
    for (uint256 i = 0; i < bins; i++) {
      nn[i] = BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: len, addFeeBuyE6: 0, addFeeSellE6: 0});
      ng[i] = BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: len, addFeeBuyE6: 0, addFeeSellE6: 0});
    }
    LO = -int16(int256(bins));
    HI = int16(int256(bins)) - 1;
    MetricOmmPoolDeployer.DeployParams memory dp;
    dp.salt = keccak256("sl");
    dp.factory = address(this);
    dp.token0 = address(a0);
    dp.token1 = address(a1);
    dp.priceProvider = address(o);
    dp.immutablePriceProvider = true;
    dp.extensions.extension1 = address(ext);
    dp.extensionOrders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
    dp.token0ScaleMultiplier = 1;
    dp.token1ScaleMultiplier = 1;
    dp.initialScaledAmount0PerShareE18 = 1e18;
    dp.initialScaledAmount1PerShareE18 = 1e18;
    dp.minimalOperationalLiquidity = 1e6;
    dp.spreadFeeE6 = 150_000;
    dp.nonNegativeBinStates = nn;
    dp.negativeBinStates = ng;
    dp.bidAskRefAsymmetryX8 = type(uint16).max;
    p = MetricOmmPool(deployer.deploy(dp));
    priceProviderTimelock[address(p)] = type(uint256).max;
    poolAdmin[address(p)] = address(this);
    poolFeeConfig[address(p)] =
      PoolFeeConfig({protocolSpreadFeeE6: 150_000, adminSpreadFeeE6: 0, protocolNotionalFeeE8: 0, adminNotionalFeeE8: 0});
    poolAdminFeeDestination[address(p)] = makeAddr("adminDest");
    // factory-only initialize: drawdown, no decay, no timelock
    ext.initialize(address(p), abi.encode(uint32(dd), uint64(0), uint40(0)));
  }

  function isPool(address) external pure returns (bool) {
    return true;
  }

  function _actor(string memory name) internal returns (address u, TestCaller c) {
    u = makeAddr(name);
    c = new TestCaller(u, address(this));
    a0.mint(address(c), 1_000_000e18);
    a1.mint(address(c), 1_000_000e18);
    vm.startPrank(address(c));
    a0.approve(address(p), type(uint256).max);
    a1.approve(address(p), type(uint256).max);
    vm.stopPrank();
  }

  function setUp() public {
    dd = _env("SL_DD_E6", 20_000);
    deployer = new MetricOmmPoolDeployer(address(this));
    ext = new OracleValueStopLossExtension(address(this));
    a0 = new MockERC20("A0", "A0", 18);
    a1 = new MockERC20("A1", "A1", 18);
    o = new MockPriceProvider();
    midTrue = 1 << 64; // true price 1.0
    uint256 hs = _env("SL_HALFSPREAD_E6", 500);
    o.setBidAndAskPrice(uint128(Math.mulDiv(midTrue, 1e6 - hs, 1e6)), uint128(Math.mulDiv(midTrue, 1e6 + hs, 1e6)));
    _deploy();
    (atkU, atkC) = _actor("attacker");
    (lpU, lpC) = _actor("honestLP");
    (keeperU, keeperC) = _actor("keeper");

    uint256 n = uint256(int256(HI) - int256(LO) + 1);
    int256[] memory idx = new int256[](n);
    uint256[] memory sh = new uint256[](n);
    for (uint256 i = 0; i < n; i++) {
      idx[i] = int256(LO) + int256(i);
      sh[i] = 1e21;
    }
    vm.prank(lpU);
    lpC.addLiquidity(address(p), 0, LiquidityDelta({binIdxs: idx, shares: sh}));

    // seed every bin's watermark at the true price: sweep all the way up, then all the way down, then back to the middle
    vm.startPrank(keeperU);
    keeperC.swap(address(p), address(keeperC), false, int128(int256(100_000e18)), type(uint128).max);
    keeperC.swap(address(p), address(keeperC), true, int128(int256(100_000e18)), 0);
    vm.stopPrank();
    (, int16 cb,,,,,) = PoolStateLibrary._slot0(address(p));
    vm.prank(keeperU);
    keeperC.swap(address(p), address(keeperC), false, int128(int256(uint256(int256(-cb)) * 1e21 / 2 + 1e18)), type(uint128).max);

    h = new SLHandler(p, o, a0, a1, atkC, atkU, LO, HI, midTrue, hs, _env("SL_MOVE_E6", 80_000));
    targetContract(address(h));
    bytes4[] memory sel = new bytes4[](4);
    sel[0] = SLHandler.moveOracle.selector;
    sel[1] = SLHandler.swap.selector;
    sel[2] = SLHandler.addLiq.selector;
    sel[3] = SLHandler.removeLiq.selector;
    targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    lpStart = _lpValueTrue();
  }

  function _lpValueTrue() internal view returns (uint256 v) {
    for (int16 b = LO; b <= HI; b++) {
      uint256 s = PoolStateLibrary._positionBinShares(address(p), address(lpC), 0, b);
      if (s == 0) continue;
      uint256 tot = PoolStateLibrary._binTotalShares(address(p), b);
      (uint104 x0, uint104 x1,,,) = PoolStateLibrary._binState(address(p), b);
      v += Math.mulDiv(Math.mulDiv(x0, s, tot), midTrue, 1 << 64) + Math.mulDiv(x1, s, tot);
    }
  }

  /// the passive LP never loses more than the drawdown (plus 0.05% for in-bin pricing and rounding) at the TRUE price
  function invariant_stopLossBoundsLpLoss() public {
    uint256 v = _lpValueTrue();
    if (v < lpStart) {
      uint256 lossE6 = (lpStart - v) * 1e6 / lpStart;
      if (lossE6 > worstLossE6) worstLossE6 = lossE6;
      if (lossE6 > dd + 500) {
        emit log_named_uint("LP loss E6", lossE6);
        emit log_named_uint("drawdown E6", dd);
        emit log_named_int("last oracle dev E6", h.lastDevE6());
      }
      assertLe(lossE6, dd + 500, "passive LP lost more than the stop-loss drawdown");
    }
  }

  function afterInvariant() public {
    emit log_named_uint("swaps ok", h.nSwapOk());
    emit log_named_uint("swaps stopped by stop-loss", h.nStopped());
    emit log_named_uint("oracle moves", h.nMoves());
    emit log_named_uint("worst LP loss E6 (this run)", worstLossE6);
  }
}
