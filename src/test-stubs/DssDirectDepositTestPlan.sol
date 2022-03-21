// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2021-2022 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.6.12;

import "./DssDirectDepositTestGem.sol";

interface DaiJoinLike {
    function dai() external view returns (address);
    function join(address, uint256) external;
    function exit(address, uint256) external;
}

contract DssDirectDepositTestPlan {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) external auth {
        wards[usr] = 1;

        emit Rely(usr);
    }
    function deny(address usr) external auth {
        wards[usr] = 0;

        emit Deny(usr);
    }
    modifier auth {
        require(wards[msg.sender] == 1, "DssDirectDepositTestJoin/not-authorized");
        _;
    }

    address public immutable dai;
    address public immutable pool;

    // test helper variables
    uint256 maxBar_;
    uint256 supplyAmount;
    uint256 targetSupply;
    uint256 currentRate;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    constructor(address dai_, address pool_) public {

        pool = pool_;
        dai = dai_;

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Testing Admin ---
    function file(bytes32 what, uint256 data) external auth {
        if (what == "maxBar_") {
            maxBar_ = data;
        } else if (what == "supplyAmount") {
            supplyAmount = data;
        } else if (what == "targetSupply") {
            targetSupply = data;
        } else if (what == "currentRate") {
            currentRate = data;
        }
    }

    function maxBar() external view returns (uint256) {
        return maxBar_;
    }

    function calcSupplies(uint256 availableLiquidity, uint256 bar) external view returns (uint256, uint256) {
        availableLiquidity;

        return (supplyAmount, bar > 0 ? targetSupply : 0);
    }

    function getCurrentRate() public view returns (uint256) {
        return currentRate;
    }
}
