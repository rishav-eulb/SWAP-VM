// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @title IValuationOracle
/// @notice Interface for oracles that provide asset valuations in the range (0, 1e18)
/// @dev Valuation v represents: v units of tokenX are worth (1e18 - v) units of tokenY
interface IValuationOracle {
    /// @notice Get the current valuation for a token pair
    /// @param tokenX The first token (corresponds to balanceIn in SwapVM)
    /// @param tokenY The second token (corresponds to balanceOut in SwapVM)
    /// @return valuation The valuation v scaled by 1e18, where v ∈ (0, 1e18)
    ///         At stable point: Y/X = v/(1e18 - v)
    function getValuation(address tokenX, address tokenY) external view returns (uint256 valuation);
    
    /// @notice Get valuation with staleness check
    /// @param tokenX The first token
    /// @param tokenY The second token
    /// @return valuation The valuation v scaled by 1e18
    /// @return updatedAt Timestamp of last update
    function getValuationWithTimestamp(address tokenX, address tokenY) 
        external view returns (uint256 valuation, uint256 updatedAt);
}