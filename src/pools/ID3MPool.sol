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

interface ID3MPool {
    function deposit(uint256 amt) external;
    function withdraw(uint256 amt) external;
    function transfer(address dst, uint256 amt) external returns (bool);
    function transferAll(address dst) external returns (bool);
    function accrueIfNeeded() external;
    function assetBalance() external view returns (uint256);
    function maxDeposit() external view returns (uint256);
    function maxWithdraw() external view returns (uint256);
    function recoverTokens(address token, address dst, uint256 amt) external returns (bool);
    function active() external view returns (bool);
}
