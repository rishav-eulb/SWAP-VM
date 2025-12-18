# Pseudo Arbitrage in SwapVM

## Technical Deep Dive

---

## Executive Summary

**Pseudo arbitrage** refers to the extraction of value from price inefficiencies within the SwapVM ecosystem without requiring external liquidity sources. Unlike traditional arbitrage that exploits price differences across distinct exchanges (DEX-to-DEX), pseudo arbitrage operates entirely within SwapVM's order space—leveraging temporal dynamics, cross-order routing, and isolated liquidity mismatches to generate risk-free profits.

---

## 1. Conceptual Framework

### 1.1 Traditional vs. Pseudo Arbitrage

| Aspect | Traditional Arbitrage | Pseudo Arbitrage |
|--------|----------------------|------------------|
| **Venue** | Cross-exchange (Uniswap ↔ Sushiswap) | Intra-ecosystem (SwapVM orders) |
| **Liquidity Source** | External AMM pools | Maker order balances |
| **Price Discovery** | Global market forces | Maker-defined rates + time functions |
| **Capital Requirements** | Flash loans often needed | Direct order execution |
| **MEV Exposure** | High (mempool competition) | Configurable (decay protection) |
| **Execution Complexity** | Multi-contract orchestration | Single VM execution |

### 1.2 Value Sources in SwapVM

```
┌─────────────────────────────────────────────────────────────────┐
│                 PSEUDO ARBITRAGE VALUE SOURCES                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. STATIC RATE DIFFERENTIALS                                   │
│     └─ Orders with different exchange rates for same pair       │
│                                                                 │
│  2. TEMPORAL DECAY                                              │
│     ├─ Dutch Auctions (price improves over time)                │
│     └─ Mooniswap-style Decay (virtual balance recovery)         │
│                                                                 │
│  3. ISOLATED LIQUIDITY FRAGMENTATION                            │
│     └─ Each maker's AMM operates independently                  │
│                                                                 │
│  4. CROSS-ORDER ROUTING                                         │
│     └─ Chaining orders for synthetic pairs                      │
│                                                                 │
│  5. INSTRUCTION COMPOSITION ARTIFACTS                           │
│     └─ Fee structures creating arbitrageable spreads            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Mechanism Deep Dive

### 2.1 Static Rate Differential Arbitrage

When multiple makers offer the same token pair at different rates, a taker can execute against the more favorable order.

**Scenario:**
```
Maker A: Sell 1000 USDC for 0.5 WETH  (rate: 2000 USDC/WETH)
Maker B: Sell 1000 USDC for 0.45 WETH (rate: 2222 USDC/WETH)
```

**Arbitrage Execution:**
```solidity
// Taker holds WETH, wants to maximize USDC acquisition

// Execute against Maker A (better rate)
swapVM.swap(
    orderA,
    WETH,           // tokenIn
    USDC,           // tokenOut
    0.5e18,         // 0.5 WETH in
    takerTraits     // receives 1000 USDC
);

// Profit: Same USDC output for same WETH input,
// but opportunity cost vs. Maker B = 111 USDC advantage
```

**Register State Flow:**
```
Initial:  balanceIn=0.5e18  balanceOut=1000e6  amountIn=0.5e18  amountOut=0
After:    balanceIn=0.5e18  balanceOut=1000e6  amountIn=0.5e18  amountOut=1000e6
```

### 2.2 Temporal Arbitrage via Dutch Auctions

Dutch auctions create time-dependent pricing where the exchange rate improves for takers over the auction duration.

**Dutch Auction Mechanics:**

```solidity
// From DutchAuction.sol - Balance decay over time
function _dutchAuctionBalanceOut1D(Context memory ctx, bytes calldata args) internal view {
    (uint256 startTime, uint256 duration, uint256 decayFactor) = DutchAuctionArgsBuilder.parse(args);
    uint256 elapsed = block.timestamp - startTime;
    uint256 decay = decayFactor.pow(elapsed, 1e18);
    
    // Balance OUT increases over time (better for taker)
    ctx.swap.balanceOut = ctx.swap.balanceOut * 1e18 / decay;
}
```

**Arbitrage Opportunity:**

```
Time T₀:        balanceOut = 1000 USDC (maker's initial offer)
Time T₀ + 60s:  balanceOut = 1020 USDC (2% improvement)
Time T₀ + 120s: balanceOut = 1041 USDC (4.1% improvement)
```

**Strategy:**
- Monitor auction orders approaching optimal execution windows
- Execute when `expectedOutput - gasCost > profitThreshold`
- Race conditions managed via threshold protection

**Code Path:**
```
quote() → Context.runLoop() → _dutchAuctionBalanceOut1D() → _limitSwap1D()
                                      │
                                      ▼
                              decay = 0.999^elapsed
                              balanceOut *= 1e18 / decay
```

### 2.3 Virtual Balance Decay (MEV Protection as Opportunity)

The `_decayXD` instruction implements Mooniswap-style virtual reserves that create temporary price dislocations.

**Decay Mechanics:**

```solidity
// From Decay.sol
function _decayXD(Context memory ctx, bytes calldata args) internal {
    uint256 period = DecayArgsBuilder.parse(args);
    
    // Adjust balances by decayed offsets
    ctx.swap.balanceIn += _offsets[orderHash][tokenIn][true].getOffset(period);
    ctx.swap.balanceOut -= _offsets[orderHash][tokenOut][false].getOffset(period);
    
    // Execute swap with adjusted balances
    (swapAmountIn, swapAmountOut) = ctx.runLoop();
    
    // Store new offsets for decay
    _offsets[orderHash][tokenIn][false].addOffset(swapAmountIn, period);
    _offsets[orderHash][tokenOut][true].addOffset(swapAmountOut, period);
}
```

**Arbitrage Window:**

```
T₀: Large swap executes → offsets created → effective price worsened
T₀ + decay_period: Offsets decay → price normalizes → arbitrage window opens

┌────────────────────────────────────────────────────────────────┐
│  DECAY ARBITRAGE TIMELINE                                      │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  Price                                                         │
│    │                                                           │
│    │    ┌───────────┐                                         │
│    │    │  Worse    │ ← After large swap (MEV protection)     │
│    │    │  Price    │                                         │
│    │────┼───────────┼────────────────────────────             │
│    │    │           │         ↘                               │
│    │    │           │           ↘ Decay recovery              │
│    │    │           │             ↘                           │
│    │────┼───────────┼───────────────●──────────── Fair Price  │
│    │    │           │                                         │
│    └────┴───────────┴────────────────────────────► Time       │
│         T₀          T₀+period                                 │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

**Execution Strategy:**
1. Monitor orders with decay protection
2. Identify when `decayedPrice` approaches `fairMarketPrice`
3. Execute small swaps to capture the normalized rate

### 2.4 Isolated Liquidity Fragmentation

Each maker's dynamic balance order operates as an **isolated AMM**. This creates structural arbitrage when different makers' curves diverge.

**XYC Swap (Constant Product):**

```solidity
// From XYCSwap.sol
function _xycSwapXD(Context memory ctx, bytes calldata /* args */) internal pure {
    if (ctx.query.isExactIn) {
        ctx.swap.amountOut = (
            (ctx.swap.amountIn * ctx.swap.balanceOut) /
            (ctx.swap.balanceIn + ctx.swap.amountIn)
        );
    } else {
        ctx.swap.amountIn = Math.ceilDiv(
            ctx.swap.amountOut * ctx.swap.balanceIn,
            (ctx.swap.balanceOut - ctx.swap.amountOut)
        );
    }
}
```

**Fragmentation Arbitrage:**

```
Maker A's AMM: balanceIn=100 ETH, balanceOut=200,000 USDC
              → Spot price: 2000 USDC/ETH
              → k = 20,000,000

Maker B's AMM: balanceIn=50 ETH, balanceOut=110,000 USDC  
              → Spot price: 2200 USDC/ETH
              → k = 5,500,000

ARBITRAGE OPPORTUNITY:
1. Buy ETH from Maker A at 2000 USDC/ETH
2. Sell ETH to Maker B at 2200 USDC/ETH
3. Profit: ~200 USDC/ETH (minus fees/slippage)
```

**Implementation:**
```solidity
// Pseudo-code for cross-order arbitrage
function executeFragmentationArbitrage(
    ISwapVM.Order memory orderA,  // Buy ETH
    ISwapVM.Order memory orderB,  // Sell ETH
    uint256 optimalAmount
) external {
    // Step 1: Buy ETH from cheaper source (Maker A)
    (uint256 usdcIn, uint256 ethOut,) = swapVM.swap(
        orderA,
        USDC,
        WETH,
        optimalAmount,
        takerTraitsA
    );
    
    // Step 2: Sell ETH to expensive source (Maker B)
    (uint256 ethIn, uint256 usdcOut,) = swapVM.swap(
        orderB,
        WETH,
        USDC,
        ethOut,
        takerTraitsB
    );
    
    // Profit = usdcOut - usdcIn
    require(usdcOut > usdcIn, "No arbitrage opportunity");
}
```

### 2.5 Cross-Order Synthetic Routing

Creating synthetic trading pairs by chaining orders that don't directly exist.

**Scenario:**
```
Available Orders:
  Order 1: WETH → USDC (Maker A)
  Order 2: USDC → DAI (Maker B)
  Order 3: DAI → WBTC (Maker C)

Synthetic Route: WETH → WBTC (via USDC → DAI)
```

**Arbitrage Detection:**
```
Direct market rate: 1 WETH = 0.05 WBTC
Synthetic rate:     1 WETH → 2000 USDC → 2000 DAI → 0.052 WBTC

Profit: 0.002 WBTC per WETH (4% improvement)
```

---

## 3. Mathematical Framework

### 3.1 Limit Order Rate Calculation

For static balance limit orders:
```
rate = balanceOut / balanceIn

Given:
  balanceIn = 1000e6 (1000 USDC)
  balanceOut = 0.5e18 (0.5 WETH)
  
rate = 0.5e18 / 1000e6 = 0.0005 WETH/USDC
     = 2000 USDC/WETH (inverse)
```

### 3.2 XYC Swap Price Impact

Constant product formula:
```
x * y = k (invariant)

For exactIn swap of Δx:
  Δy = (Δx * y) / (x + Δx)

Price impact = 1 - (Δy/Δx) / (y/x)
             = Δx / (x + Δx)
```

### 3.3 Dutch Auction Decay

Exponential decay over time:
```
decay(t) = decayFactor^t

For balanceOut adjustment:
  effectiveBalanceOut = initialBalanceOut * (1e18 / decay(t))
                      = initialBalanceOut * decayFactor^(-t)

Rate improvement over time:
  t=0:   rate = balanceOut / balanceIn
  t=60:  rate = (balanceOut * 1.0618) / balanceIn  [~6.18% better for decayFactor=0.999]
```

### 3.4 Arbitrage Profit Calculation

```
profit = Σ(output_i) - Σ(input_i) - gasCost

For two-order arbitrage:
  profit = (amountOut_B - amountIn_A) - gasCost
  
Constraints:
  amountIn_A = initial capital
  amountOut_A = amountIn_B (chained)
  amountOut_B = final output
```

---

## 4. Execution Strategies

### 4.1 Order Discovery Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                  ARBITRAGE DISCOVERY FLOW                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. INDEX ACTIVE ORDERS                                     │
│     ├─ Subscribe to Swapped events                          │
│     ├─ Track order signatures and programs                  │
│     └─ Decode balance configurations                        │
│                                                             │
│  2. COMPUTE EFFECTIVE RATES                                 │
│     ├─ Static: balanceOut / balanceIn                       │
│     ├─ Dynamic: Simulate XYC curve at various sizes         │
│     └─ Temporal: Project Dutch auction decay               │
│                                                             │
│  3. IDENTIFY RATE DIFFERENTIALS                             │
│     ├─ Same-pair comparisons                                │
│     ├─ Synthetic route construction                         │
│     └─ Cross-maker fragmentation analysis                   │
│                                                             │
│  4. SIMULATE PROFITABILITY                                  │
│     ├─ quote() all candidate orders                         │
│     ├─ Account for fees and slippage                        │
│     └─ Estimate gas costs                                   │
│                                                             │
│  5. EXECUTE                                                 │
│     └─ Atomic multi-swap transaction                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Optimal Execution Sizing

For XYC-based AMM orders, optimal arbitrage size follows:

```solidity
function calculateOptimalArbitrage(
    uint256 x_a, uint256 y_a,  // Maker A reserves
    uint256 x_b, uint256 y_b   // Maker B reserves
) pure returns (uint256 optimalInput) {
    // Price A < Price B assumption (y_a/x_a < y_b/x_b)
    // Optimal: sqrt(x_a * y_a * x_b / y_b) - x_a
    
    uint256 geometric = sqrt(x_a * y_a * x_b / y_b);
    optimalInput = geometric > x_a ? geometric - x_a : 0;
}
```

### 4.3 Gas-Efficient Batching

```solidity
// Multi-order arbitrage in single transaction
function batchArbitrage(
    ISwapVM.Order[] calldata orders,
    bytes[] calldata takerData,
    address[] calldata tokensIn,
    address[] calldata tokensOut,
    uint256[] calldata amounts
) external {
    uint256 profit;
    
    for (uint256 i = 0; i < orders.length; i++) {
        (uint256 amountIn, uint256 amountOut,) = swapVM.swap(
            orders[i],
            tokensIn[i],
            tokensOut[i],
            amounts[i],
            takerData[i]
        );
        
        // Track cumulative profit
        profit += _calculateStepProfit(amountIn, amountOut, tokensIn[i], tokensOut[i]);
    }
    
    require(profit > 0, "Unprofitable arbitrage");
}
```

---

## 5. Risk Considerations

### 5.1 Execution Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| **Front-running** | MEV bots copying profitable transactions | Private mempools (Flashbots) |
| **State Changes** | Order balances change between quote/swap | Tight threshold parameters |
| **Gas Volatility** | Unpredictable execution costs | Dynamic gas pricing in profit calc |
| **Decay Timing** | Dutch auction timing uncertainty | Timestamp buffer margins |

### 5.2 Threshold Protection Usage

```solidity
TakerTraitsLib.Args memory args = TakerTraitsLib.Args({
    isExactIn: true,
    threshold: minAcceptableOutput,  // CRITICAL: Set tight thresholds
    to: msg.sender,
    shouldUnwrapWeth: false,
    // ...
});
```

### 5.3 Quote-Then-Execute Pattern

```solidity
// Always preview before execution
(uint256 quotedIn, uint256 quotedOut,) = swapVM.asView().quote(
    order, tokenIn, tokenOut, amount, takerTraits
);

// Validate profitability
require(quotedOut >= minProfit + gasCost, "Below threshold");

// Execute with tight slippage
(uint256 actualIn, uint256 actualOut,) = swapVM.swap(
    order, tokenIn, tokenOut, amount, takerTraitsWithThreshold
);
```

---

## 6. Implementation Reference

### 6.1 Arbitrage Bot Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│                    PSEUDO ARBITRAGE BOT                           │
├───────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐   │
│  │   INDEXER   │───▶│  ANALYZER   │───▶│  EXECUTION ENGINE   │   │
│  └─────────────┘    └─────────────┘    └─────────────────────┘   │
│         │                  │                      │               │
│         ▼                  ▼                      ▼               │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐   │
│  │ Order Store │    │ Rate Graph  │    │ Transaction Builder │   │
│  │ (SQLite/PG) │    │ (In-memory) │    │ (Ethers.js/Viem)    │   │
│  └─────────────┘    └─────────────┘    └─────────────────────┘   │
│                                                                   │
│  COMPONENTS:                                                      │
│  ─────────────                                                    │
│  • Event listener for Swapped events                              │
│  • Program bytecode decoder                                       │
│  • Rate calculator (static/dynamic/temporal)                      │
│  • Graph-based route finder                                       │
│  • Profit simulator with gas estimation                           │
│  • Flashbots bundle submitter                                     │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### 6.2 Key Contract Interactions

```solidity
interface IPseudoArbitrage {
    /// @notice Find arbitrage between two orders
    function findArbitrage(
        ISwapVM.Order calldata orderA,
        ISwapVM.Order calldata orderB,
        address tokenBridge  // Common token between orders
    ) external view returns (
        uint256 optimalInput,
        uint256 expectedProfit
    );
    
    /// @notice Execute atomic arbitrage
    function executeArbitrage(
        ISwapVM.Order calldata orderA,
        ISwapVM.Order calldata orderB,
        uint256 inputAmount,
        uint256 minProfit
    ) external returns (uint256 actualProfit);
    
    /// @notice Batch multiple arbitrage opportunities
    function batchArbitrage(
        ArbitrageRoute[] calldata routes
    ) external returns (uint256 totalProfit);
}
```

---

## 7. Economic Implications

### 7.1 Market Efficiency Effects

Pseudo arbitrage in SwapVM contributes to:

1. **Price Convergence**: Arbitrageurs push maker rates toward market equilibrium
2. **Liquidity Utilization**: Fragmented liquidity becomes effectively unified
3. **MEV Redistribution**: Value extraction shifts from validators to sophisticated takers
4. **Order Quality Signaling**: Mispriced orders are quickly consumed

### 7.2 Maker Considerations

Makers should understand that pseudo arbitrage:

- **Benefits**: Orders fill faster, liquidity attracts volume
- **Risks**: Mispriced orders lose value, Dutch auctions may execute at unfavorable times
- **Protections**: Use `_decayXD` for MEV protection, set appropriate expirations

### 7.3 Ecosystem Dynamics

```
                    ┌──────────────────┐
                    │     MAKERS       │
                    │  (Provide rates) │
                    └────────┬─────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
              ▼                             ▼
    ┌─────────────────┐           ┌─────────────────┐
    │  PRICE-TAKERS   │           │  ARBITRAGEURS   │
    │ (Accept rates)  │           │ (Exploit diffs) │
    └─────────────────┘           └─────────────────┘
              │                             │
              └──────────────┬──────────────┘
                             │
                             ▼
                    ┌──────────────────┐
                    │   EQUILIBRIUM    │
                    │  (Market price)  │
                    └──────────────────┘
```

---

## 8. Conclusion

Pseudo arbitrage represents a fundamental value extraction mechanism in SwapVM's architecture. By understanding the interplay between:

- **Static rate differentials** across maker orders
- **Temporal dynamics** from Dutch auctions and decay mechanisms  
- **Liquidity fragmentation** in isolated AMM structures
- **Cross-order routing** for synthetic pairs

...sophisticated takers can construct profitable strategies that simultaneously improve market efficiency while extracting value from pricing inefficiencies.

The key insight is that SwapVM's design—where each maker controls their own pricing logic via bytecode programs—creates a rich landscape of arbitrage opportunities that don't require external liquidity venues. This "pseudo" arbitrage operates entirely within the SwapVM ecosystem, making it a unique primitive compared to traditional cross-DEX strategies.

---

## Appendix: Quick Reference

### Relevant Source Files

| File | Purpose |
|------|---------|
| `src/SwapVM.sol` | Core VM execution |
| `src/instructions/LimitSwap.sol` | Static rate swaps |
| `src/instructions/XYCSwap.sol` | Constant product AMM |
| `src/instructions/DutchAuction.sol` | Time-based price decay |
| `src/instructions/Decay.sol` | Virtual balance MEV protection |
| `src/instructions/Balances.sol` | Static/dynamic balance management |
| `src/instructions/Fee.sol` | Fee calculations |

### Key Formulas

```
Limit Rate:      rate = balanceOut / balanceIn
XYC Output:      Δy = (Δx × y) / (x + Δx)
Dutch Decay:     balance(t) = balance₀ × decayFactor^(-t)
Decay Offset:    offset(t) = offset₀ × (period - elapsed) / period
```

---

*Document Version: 1.0*  
*Last Updated: December 2024*

