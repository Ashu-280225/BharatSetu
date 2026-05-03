// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/**
 * @title ValidatorSet 
 * @notice This contract defines the interface for managing a set of validators in BharatSetu.
 */

    contract ValidatorSet {

        address public regulator;

        struct Validator {
            address ethAddress;
            bytes blsPublicKey;
            bool active;
            uint256 registeredAt;
        }   

        mapping(address => Validator) public validators;
        address[] public activeSet;

        modifier onlyRegulator() {
            require(msg.sender == regulator, "ValidatorSet: not regulator");
        _;
        }

        constructor(address _regulator) {
            require(_regulator != address(0), "ValidatorSet: Zero address");
            regulator = _regulator;
        }

        function addValidator(address v, bytes calldata blsKey) external onlyRegulator {
            require(v!= address(0), "ValidatorSet: Zero address");
            require(blsKey.length > 0, "ValidatorSet: Empty BLS key");
            require(activeSet.length < 5, "ValidatorSet: Set full");
            require(!validators[v].active, "ValidatorSet: Already active");
    
            validators[v] = Validator({
                ethAddress: v,
                blsPublicKey: blsKey,
                active: true,
                registeredAt: block.timestamp
            });

            activeSet.push(v);
        }

        function removeValidator(address v) external onlyRegulator {
            require(validators[v].active, "ValidatorSet: Not active");

            validators[v].active = false;

            for(uint i = 0; i < activeSet.length; i++) {
                if(activeSet[i]==v) {
                    activeSet[i] = activeSet[activeSet.length - 1];
                    activeSet.pop();
                    break;
                }
            }
        }


        function isQuorum(bytes[] calldata blsKeys , bytes32 /*msghash*/) 
            external 
            view 
            returns (bool) 
        {
            uint256 matchCount = 0;

                for(uint256 i = 0; i < blsKeys.length; i++) {
                    for(uint256 j = 0; j < activeSet.length; j++) {
                        if (keccak256(blsKeys[i]) == keccak256(validators[activeSet[j]].blsPublicKey)) 
                        {
                            matchCount++;
                            break;
                        }
                    }
                }
            
            return matchCount >= 3; 

        }

    }
