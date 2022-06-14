// SPDX-FileCopyrightText: © 2021-2022 Dai Foundation <www.daifoundation.org>
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

pragma solidity ^0.8.14;

import "./ID3MPool.sol";

interface TokenLike {
    function balanceOf(address)         external view returns (uint256);
    function approve(address, uint256)  external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface VatLike {
    function live() external view returns (uint256);
    function hope(address) external;
    function nope(address) external;
}

interface D3mHubLike {
    function vat() external view returns (address);
}

// https://github.com/compound-finance/compound-protocol/blob/3affca87636eecd901eb43f81a4813186393905d/contracts/CErc20.sol#L14
interface CErc20Like is TokenLike {
    function underlying()                           external view returns (address);
    function comptroller()                          external view returns (address);
    function exchangeRateStored()                   external view returns (uint256);
    function getCash()                              external view returns (uint256);
    function getAccountSnapshot(address account)    external view returns (uint256, uint256, uint256, uint256);
    function mint(uint256 mintAmount)               external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function accrueInterest()                       external returns (uint256);
    function exchangeRateCurrent()                  external returns (uint256);
}

// https://github.com/compound-finance/compound-protocol/blob/3affca87636eecd901eb43f81a4813186393905d/contracts/ComptrollerG7.sol#L15
interface ComptrollerLike {
    function getCompAddress() external view returns (address);
    function claimComp(address[] memory holders, address[] memory cTokens, bool borrowers, bool suppliers) external;
}

contract D3MCompoundPool is ID3MPool {

    mapping (address => uint256) public wards;
    address                      public hub;
    address                      public king; // Who gets the rewards

    VatLike         public immutable vat;
    ComptrollerLike public immutable comptroller;
    TokenLike       public immutable comp;
    TokenLike       public immutable dai;
    CErc20Like      public immutable cDai;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, address data);
    event Collect(address indexed king, address indexed gift, uint256 amt);

    constructor(address hub_, address cDai_) {
        cDai        = CErc20Like(cDai_);
        dai         = TokenLike(cDai.underlying());
        comptroller = ComptrollerLike(cDai.comptroller());
        comp        = TokenLike(comptroller.getCompAddress());

        require(address(comp) != address(0), "D3MCompoundPool/invalid-comp");

        dai.approve(cDai_, type(uint256).max);

        hub = hub_;
        vat = VatLike(D3mHubLike(hub).vat());
        vat.hope(hub);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    modifier auth {
        require(wards[msg.sender] == 1, "D3MCompoundPool/not-authorized");
        _;
    }

    modifier onlyHub {
        require(msg.sender == hub, "D3MCompoundPool/only-hub");
        _;
    }

    // --- Math ---
    uint256 internal constant WAD = 10 ** 18;
    function _wmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x * y) / WAD;
    }
    function _wdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x * WAD) / y;
    }
    function _min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x <= y ? x : y;
    }

    // --- Admin ---
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function file(bytes32 what, address data) external auth {
        require(vat.live() == 1, "D3MCompoundPool/no-file-during-shutdown");
        if (what == "hub") {
            vat.nope(hub);
            hub = data;
            vat.hope(data);
        } else if (what == "king") king = data;
        else revert("D3MCompoundPool/file-unrecognized-param");
        emit File(what, data);
    }

    function deposit(uint256 wad) external override onlyHub {
        uint256 prev = cDai.balanceOf(address(this));
        require(cDai.mint(wad) == 0, "D3MCompoundPool/mint-failure");
        // As interest was accrued on `mint` we can use the non accruing `exchangeRateStored`
        require(
            cDai.balanceOf(address(this)) ==
            prev + _wdiv(wad, cDai.exchangeRateStored()), "D3MCompoundPool/incorrect-cdai-credit"
        );
    }

    function withdraw(uint256 wad) external override onlyHub {
        require(cDai.redeemUnderlying(wad) == 0, "D3MCompoundPool/redeemUnderlying-failure");
        dai.transfer(msg.sender, wad);
    }

    function transfer(address dst, uint256 wad) external override onlyHub {
        require(cDai.transfer(dst, _wdiv(wad, cDai.exchangeRateCurrent())), "D3MCompoundPool/transfer-failed");
    }

    function quit(address dst) external override auth {
        require(vat.live() == 1, "D3MCompoundPool/no-quit-during-shutdown");
        require(cDai.transfer(dst, cDai.balanceOf(address(this))), "D3MCompoundPool/transfer-failed");
    }

    function preDebtChange(bytes32) external override {
        require(cDai.accrueInterest() == 0, "D3MCompoundPool/accrueInterest-failure");
    }

    function postDebtChange(bytes32) external override {}

    // Does not accrue interest (as opposed to cToken's balanceOfUnderlying() which is not a view function).
    function assetBalance() public view override returns (uint256) {
        (uint256 error, uint256 cTokenBalance,, uint256 exchangeRate) = cDai.getAccountSnapshot(address(this));
        require(error == 0, "D3MCompoundPool/getAccountSnapshot-failure");
        return _wmul(cTokenBalance, exchangeRate);
    }

    function maxDeposit() external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw() external view override returns (uint256) {
        return _min(cDai.getCash(), assetBalance());
    }

    function redeemable() external view override returns (address) {
        return address(cDai);
    }

    function collect() external {
        require(king != address(0), "D3MCompoundPool/king-not-set");

        address[] memory holders = new address[](1);
        holders[0] = address(this);
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(cDai);

        comptroller.claimComp(holders, cTokens, false, true);
        uint256 amt = comp.balanceOf(address(this));
        comp.transfer(king, amt);

        emit Collect(king, address(comp), amt);
    }
}
