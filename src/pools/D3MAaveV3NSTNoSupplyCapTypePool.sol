// SPDX-FileCopyrightText: © 2021 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
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
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface VatLike {
    function live() external view returns (uint256);
    function hope(address) external;
    function nope(address) external;
}

interface D3mHubLike {
    function vat() external view returns (address);
    function end() external view returns (EndLike);
}

interface EndLike {
    function Art(bytes32) external view returns (uint256);
}

// https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/tokenization/AToken.sol
interface ATokenLike is TokenLike {
    function scaledBalanceOf(address) external view returns (uint256);
    function getIncentivesController() external view returns (address);
}

// https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/pool/Pool.sol
interface PoolLike {

    // Need to use a struct as too many variables to return on the stack
    struct ReserveData {
        //stores the reserve configuration
        uint256 configuration;
        //the liquidity index. Expressed in ray
        uint128 liquidityIndex;
        //the current supply rate. Expressed in ray
        uint128 currentLiquidityRate;
        //variable borrow index. Expressed in ray
        uint128 variableBorrowIndex;
        //the current variable borrow rate. Expressed in ray
        uint128 currentVariableBorrowRate;
        //the current stable borrow rate. Expressed in ray
        uint128 currentStableBorrowRate;
        //timestamp of last update
        uint40 lastUpdateTimestamp;
        //the id of the reserve. Represents the position in the list of the active reserves
        uint16 id;
        //aToken address
        address aTokenAddress;
        //stableDebtToken address
        address stableDebtTokenAddress;
        //variableDebtToken address
        address variableDebtTokenAddress;
        //address of the interest rate strategy
        address interestRateStrategyAddress;
        //the current treasury balance, scaled
        uint128 accruedToTreasury;
        //the outstanding unbacked aTokens minted through the bridging feature
        uint128 unbacked;
        //the outstanding debt borrowed against this asset in isolation mode
        uint128 isolationModeTotalDebt;
    }
    
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external;
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
    function getReserveData(address asset) external view returns (ReserveData memory);
}

// https://github.com/aave/aave-v3-periphery/blob/master/contracts/rewards/RewardsController.sol
interface RewardsClaimerLike {
    function claimRewards(address[] calldata assets, uint256 amount, address to, address reward) external returns (uint256);
}

interface JoinLike {
    function dai() external view returns (address);
    function nst() external view returns (address);
    function join(address, uint256) external;
    function exit(address, uint256) external;
}

contract D3MAaveV3NSTNoSupplyCapTypePool is ID3MPool {

    mapping (address => uint256) public wards;
    address                      public hub;
    address                      public king; // Who gets the rewards
    uint256                      public exited;

    bytes32    public immutable ilk;
    VatLike    public immutable vat;
    PoolLike   public immutable pool;
    ATokenLike public immutable stableDebt;
    ATokenLike public immutable variableDebt;
    ATokenLike public immutable anst;
    JoinLike   public immutable nstJoin;
    TokenLike  public immutable nst; // Asset
    JoinLike   public immutable daiJoin;
    TokenLike  public immutable dai;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, address data);
    event Collect(address indexed king, address indexed gift, uint256 amt);

    constructor(bytes32 ilk_, address hub_, address nstJoin_, address daiJoin_, address pool_) {
        ilk = ilk_;
        nstJoin = JoinLike(nstJoin_);
        nst = TokenLike(nstJoin.nst());
        daiJoin = JoinLike(daiJoin_);
        dai = TokenLike(daiJoin.dai());
        pool = PoolLike(pool_);

        // Fetch the reserve data from Aave
        PoolLike.ReserveData memory data = pool.getReserveData(address(nst));
        require(data.aTokenAddress               != address(0), "D3MAaveV3NoSupplyCapTypePool/invalid-anst");
        require(data.stableDebtTokenAddress      != address(0), "D3MAaveV3NoSupplyCapTypePool/invalid-stableDebt");
        require(data.variableDebtTokenAddress    != address(0), "D3MAaveV3NoSupplyCapTypePool/invalid-variableDebt");

        anst = ATokenLike(data.aTokenAddress);
        stableDebt = ATokenLike(data.stableDebtTokenAddress);
        variableDebt = ATokenLike(data.variableDebtTokenAddress);

        hub = hub_;
        vat = VatLike(D3mHubLike(hub_).vat());
        vat.hope(hub_);

        nst.approve(pool_, type(uint256).max);
        dai.approve(daiJoin_, type(uint256).max);
        vat.hope(daiJoin_);
        nst.approve(nstJoin_, type(uint256).max);
        vat.hope(nstJoin_);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    modifier auth {
        require(wards[msg.sender] == 1, "D3MAaveV3NoSupplyCapTypePool/not-authorized");
        _;
    }

    modifier onlyHub {
        require(msg.sender == hub, "D3MAaveV3NoSupplyCapTypePool/only-hub");
        _;
    }

    // --- Math ---
    uint256 internal constant RAY = 10 ** 27;
    function _rdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x * RAY) / y;
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
        require(vat.live() == 1, "D3MAaveV3NoSupplyCapTypePool/no-file-during-shutdown");
        if (what == "hub") {
            vat.nope(hub);
            hub = data;
            vat.hope(data);
        } else if (what == "king") king = data;
        else revert("D3MAaveV3NoSupplyCapTypePool/file-unrecognized-param");
        emit File(what, data);
    }

    // Deposits NST to Aave in exchange for anst which is received by this contract
    // Aave: https://docs.aave.com/developers/core-contracts/pool#supply
    function deposit(uint256 wad) external override onlyHub {
        daiJoin.join(address(this), wad);
        nstJoin.exit(address(this), wad);

        uint256 scaledPrev = anst.scaledBalanceOf(address(this));

        pool.supply(address(nst), wad, address(this), 0);

        // Verify the correct amount of anst shows up
        uint256 interestIndex = pool.getReserveNormalizedIncome(address(nst));
        uint256 scaledAmount = _rdiv(wad, interestIndex);
        require(anst.scaledBalanceOf(address(this)) >= (scaledPrev + scaledAmount), "D3MAaveV3NoSupplyCapTypePool/incorrect-anst-balance-received");
    }

    // Withdraws NST from Aave in exchange for anst
    // Aave: https://docs.aave.com/developers/core-contracts/pool#withdraw
    function withdraw(uint256 wad) external override onlyHub {
        uint256 prevNst = nst.balanceOf(address(this));

        pool.withdraw(address(nst), wad, address(this));

        require(nst.balanceOf(address(this)) == prevNst + wad, "D3MAaveV3NoSupplyCapTypePool/incorrect-nst-balance-received");

        nstJoin.join(address(this), wad);
        daiJoin.exit(msg.sender, wad);
    }

    function exit(address dst, uint256 wad) external override onlyHub {
        uint256 exited_ = exited;
        exited = exited_ + wad;
        uint256 amt = wad * assetBalance() / (D3mHubLike(hub).end().Art(ilk) - exited_);
        require(anst.transfer(dst, amt), "D3MAaveV3NoSupplyCapTypePool/transfer-failed");
    }

    function quit(address dst) external override auth {
        require(vat.live() == 1, "D3MAaveV3NoSupplyCapTypePool/no-quit-during-shutdown");
        require(anst.transfer(dst, anst.balanceOf(address(this))), "D3MAaveV3NoSupplyCapTypePool/transfer-failed");
    }

    function preDebtChange() external override {}

    function postDebtChange() external override {}

    // --- Balance of the underlying asset (NST)
    function assetBalance() public view override returns (uint256) {
        return anst.balanceOf(address(this));
    }

    function maxDeposit() external pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw() external view override returns (uint256) {
        return _min(nst.balanceOf(address(anst)), assetBalance());
    }

    function redeemable() external view override returns (address) {
        return address(anst);
    }

    // --- Collect any rewards ---
    function collect(address gift) external returns (uint256 amt) {
        require(king != address(0), "D3MAaveV3NoSupplyCapTypePool/king-not-set");

        address[] memory assets = new address[](1);
        assets[0] = address(anst);

        RewardsClaimerLike rewardsClaimer = RewardsClaimerLike(anst.getIncentivesController());

        amt = rewardsClaimer.claimRewards(assets, type(uint256).max, king, gift);
        emit Collect(king, gift, amt);
    }
}
