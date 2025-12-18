// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { IValuationOracle } from "../instructions/interfaces/IValuationOracle.sol";
import { IPriceOracle } from "../instructions/interfaces/IPriceOracle.sol";

/**
 * @title ChainlinkValuationOracle
 * @notice Converts Chainlink price feeds to valuation format for ValuationAdjust
 * @dev Valuation v = priceX / (priceX + priceY) where prices are in same denomination (e.g., USD)
 * 
 * Mathematical basis:
 *   The valuation v represents what fraction of combined value token X represents.
 *   At equilibrium, the AMM should satisfy: Y/X = v/(1-v) = priceX/priceY
 *   
 *   Derivation:
 *     v/(1-v) = priceX/priceY
 *     v * priceY = (1-v) * priceX
 *     v * priceY = priceX - v * priceX
 *     v * (priceX + priceY) = priceX
 *     v = priceX / (priceX + priceY)
 * 
 * Example:
 *   ETH price = $3000, USDC price = $1
 *   v = 3000 / (3000 + 1) ≈ 0.9997
 *   Target ratio: Y/X = v/(1-v) ≈ 3000 USDC per ETH
 */
contract ChainlinkValuationOracle is IValuationOracle {
    
    error OracleNotConfigured(address token);
    error InvalidPrice(address token, int256 price);
    error OnlyOwner();
    error ZeroAddress();
    error SamePriceFeed();
    
    event PriceFeedSet(address indexed token, address indexed priceFeed);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    /// @notice Mapping from token address to Chainlink price feed
    mapping(address => address) public priceFeeds;
    
    /// @notice Decimals for each price feed (cached to save gas)
    mapping(address => uint8) public feedDecimals;
    
    /// @notice Owner for configuration
    address public owner;
    
    modifier onlyOwner() {
        require(msg.sender == owner, OnlyOwner());
        _;
    }
    
    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }
    
    /// @notice Transfer ownership to a new address
    /// @param newOwner The address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), ZeroAddress());
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
    
    /// @notice Configure a price feed for a token
    /// @param token The token address
    /// @param priceFeed The Chainlink aggregator address (address(0) to remove)
    function setPriceFeed(address token, address priceFeed) external onlyOwner {
        require(token != address(0), ZeroAddress());
        
        priceFeeds[token] = priceFeed;
        if (priceFeed != address(0)) {
            feedDecimals[token] = IPriceOracle(priceFeed).decimals();
        } else {
            feedDecimals[token] = 0;
        }
        
        emit PriceFeedSet(token, priceFeed);
    }
    
    /// @notice Batch configure price feeds for multiple tokens
    /// @param tokens Array of token addresses
    /// @param feeds Array of Chainlink aggregator addresses
    function setPriceFeeds(address[] calldata tokens, address[] calldata feeds) external onlyOwner {
        require(tokens.length == feeds.length, "Length mismatch");
        
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), ZeroAddress());
            
            priceFeeds[tokens[i]] = feeds[i];
            if (feeds[i] != address(0)) {
                feedDecimals[tokens[i]] = IPriceOracle(feeds[i]).decimals();
            } else {
                feedDecimals[tokens[i]] = 0;
            }
            
            emit PriceFeedSet(tokens[i], feeds[i]);
        }
    }
    
    /// @inheritdoc IValuationOracle
    function getValuation(address tokenX, address tokenY) external view returns (uint256 valuation) {
        require(tokenX != tokenY, SamePriceFeed());
        
        uint256 priceX = _getPrice(tokenX);
        uint256 priceY = _getPrice(tokenY);
        
        // v = priceX / (priceX + priceY)
        // Scaled to 1e18 precision
        valuation = (priceX * 1e18) / (priceX + priceY);
    }
    
    /// @inheritdoc IValuationOracle
    function getValuationWithTimestamp(address tokenX, address tokenY) 
        external view returns (uint256 valuation, uint256 updatedAt) 
    {
        require(tokenX != tokenY, SamePriceFeed());
        
        (uint256 priceX, uint256 timestampX) = _getPriceWithTimestamp(tokenX);
        (uint256 priceY, uint256 timestampY) = _getPriceWithTimestamp(tokenY);
        
        valuation = (priceX * 1e18) / (priceX + priceY);
        // Use older timestamp as the "freshness" indicator (conservative approach)
        updatedAt = timestampX < timestampY ? timestampX : timestampY;
    }
    
    /// @notice Get the raw price for a token (normalized to 18 decimals)
    /// @param token The token address
    /// @return price The price normalized to 18 decimals
    function getPrice(address token) external view returns (uint256 price) {
        return _getPrice(token);
    }
    
    function _getPrice(address token) private view returns (uint256) {
        address feed = priceFeeds[token];
        require(feed != address(0), OracleNotConfigured(token));
        
        (, int256 answer,,,) = IPriceOracle(feed).latestRoundData();
        require(answer > 0, InvalidPrice(token, answer));
        
        // Normalize to 18 decimals
        return _normalizeDecimals(uint256(answer), feedDecimals[token]);
    }
    
    function _getPriceWithTimestamp(address token) private view returns (uint256 price, uint256 updatedAt) {
        address feed = priceFeeds[token];
        require(feed != address(0), OracleNotConfigured(token));
        
        (, int256 answer,, uint256 timestamp,) = IPriceOracle(feed).latestRoundData();
        require(answer > 0, InvalidPrice(token, answer));
        
        price = _normalizeDecimals(uint256(answer), feedDecimals[token]);
        updatedAt = timestamp;
    }
    
    function _normalizeDecimals(uint256 value, uint8 decimals) private pure returns (uint256) {
        if (decimals < 18) {
            return value * 10**(18 - decimals);
        } else if (decimals > 18) {
            return value / 10**(decimals - 18);
        }
        return value;
    }
}
