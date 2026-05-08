// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
PURPOSE:
- Register supported tokens
- Enable/disable tokens
- Check if token is supported
*/

contract TokenRegistry {

    address public regulator;

    struct TokenConfig {
        address token;
        uint8 decimals;
        bool active;
    }

    mapping(address => TokenConfig) public tokens;

    constructor(address _regulator) {
        regulator = _regulator;
    }

    modifier onlyRegulator() {
        require(msg.sender == regulator, "Not regulator");
        _;
    }

    /*
    FUNCTION: registerToken
    PURPOSE:
    - Add a new token to registry
    */
    function registerToken(address token, uint8 decimals) external onlyRegulator {
        tokens[token] = TokenConfig({
            token: token,
            decimals: decimals,
            active: true
        });
    }

    /*
    FUNCTION: deactivateToken
    PURPOSE:
    - Disable token support
    */
    function deactivateToken(address token) external onlyRegulator {
        tokens[token].active = false;
    }

    /*
    FUNCTION: isSupported
    PURPOSE:
    - Check if token is active
    */
    function isSupported(address token) external view returns (bool) {
        return tokens[token].active;
    }
}