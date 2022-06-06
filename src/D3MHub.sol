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

import "./pools/ID3MPool.sol";
import "./plans/ID3MPlan.sol";

interface VatLike {
    function debt() external view returns (uint256);
    function hope(address) external;
    function nope(address) external;
    function ilks(bytes32) external view returns (uint256, uint256, uint256, uint256, uint256);
    function Line() external view returns (uint256);
    function urns(bytes32, address) external view returns (uint256, uint256);
    function gem(bytes32, address) external view returns (uint256);
    function live() external view returns (uint256);
    function slip(bytes32, address, int256) external;
    function move(address, address, uint256) external;
    function frob(bytes32, address, address, address, int256, int256) external;
    function grab(bytes32, address, address, address, int256, int256) external;
    function fork(bytes32, address, address, int256, int256) external;
    function suck(address, address, uint256) external;
}

interface EndLike {
    function debt() external view returns (uint256);
    function skim(bytes32, address) external;
}

interface DaiJoinLike {
    function dai() external view returns (address);
    function join(address, uint256) external;
    function exit(address, uint256) external;
}

interface TokenLike {
    function approve(address, uint256) external returns (bool);
}

/**
    @title D3M Hub
    @notice This is the main D3M contract and is responsible for winding and
    unwinding pools, interacting with DSS and tracking the plans and pools and
    their states.
*/
contract D3MHub {

    // --- Auth ---
    /**
        @notice Maps address that have permission in the Pool.
        @dev 1 = allowed, 0 = no permission
        @return authorization 1 or 0
    */
    mapping (address => uint256) public wards;

    address public vow;
    EndLike public end;
    uint256 public locked;

    /// @notice maps ilk bytes32 to the D3M tracking struct.
    mapping (bytes32 => Ilk) public ilks;
    
    VatLike     public immutable vat;
    DaiJoinLike public immutable daiJoin;

    enum Mode { NORMAL, MODULE_CULLED, MCD_CAGED }

    /**
        @notice Tracking struct for each of the D3M ilks.
        @param pool   Contract to access external pool and hold balances
        @param plan   Contract used to calculate target debt
        @param tau    Time until you can write off the debt [sec]
        @param culled Debt write off triggered (1 or 0)
        @param tic    Timestamp when the pool is caged
    */
    struct Ilk {
        ID3MPool pool;   // Access external pool and holds balances
        ID3MPlan plan;   // How we calculate target debt
        uint256  tau;    // Time until you can write off the debt [sec]
        uint256  culled; // Debt write off triggered
        uint256  tic;    // Timestamp when the d3m can be culled (tau + timestamp when caged)
    }

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed ilk, bytes32 indexed what, address data);
    event File(bytes32 indexed ilk, bytes32 indexed what, uint256 data);
    event Wind(bytes32 indexed ilk, uint256 amount);
    event Unwind(bytes32 indexed ilk, uint256 amount, uint256 fees);
    event Reap(bytes32 indexed ilk, uint256 amt);
    event Cage(bytes32 indexed ilk);
    event Cull(bytes32 indexed ilk, uint256 ink, uint256 art);
    event Uncull(bytes32 indexed ilk, uint256 wad);
    event Quit(bytes32 indexed ilk, address indexed usr);
    event Exit(bytes32 indexed ilk, address indexed usr, uint256 amt);

    /**
        @dev sets msg.sender as authed.
        @param vat_     address of the DSS vat contract
        @param daiJoin_ address of the DSS Dai Join contract
    */
    constructor(address vat_, address daiJoin_) {
        vat = VatLike(vat_);
        daiJoin = DaiJoinLike(daiJoin_);
        TokenLike(DaiJoinLike(daiJoin_).dai()).approve(daiJoin_, type(uint256).max);
        VatLike(vat_).hope(daiJoin_);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    /// @notice Modifier will revoke if msg.sender is not authorized.
    modifier auth {
        require(wards[msg.sender] == 1, "D3MHub/not-authorized");
        _;
    }

    /// @notice Mutex to prevent reentrancy on external functions
    modifier lock {
        require(locked == 0, "D3MHub/system-locked");
        locked = 1;
        _;
        locked = 0;
    }

    // --- Math ---
    uint256 internal constant RAY = 10 ** 27;
    uint256 internal constant MAXINT256 = uint256(type(int256).max);

    function _min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x <= y ? x : y;
    }
    function _max(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x >= y ? x : y;
    }
    function _divup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x + (y - 1)) / y;
    }

    // --- Administration ---
    /**
        @notice Makes an address authorized to perform auth'ed functions.
        @dev msg.sender must be authorized.
        @param usr address to be authorized
    */
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    /**
        @notice De-authorizes an address from performing auth'ed functions.
        @dev msg.sender must be authorized.
        @param usr address to be de-authorized
    */
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    /**
        @notice update vow or end addresses.
        @dev msg.sender must be authorized.
        @param what name of what we are updating bytes32("vow"|"end")
        @param data address we are setting it to
    */
    function file(bytes32 what, address data) external auth {
        require(vat.live() == 1, "D3MHub/no-file-during-shutdown");

        if (what == "vow") vow = data;
        else if (what == "end") end = EndLike(data);
        else revert("D3MHub/file-unrecognized-param");
        emit File(what, data);
    }

    /**
        @notice update tau value for D3M ilk.
        @dev msg.sender must be authorized.
        @param ilk  bytes32 of the D3M ilk to be updated
        @param what bytes32("tau") or it will revert
        @param data number of seconds to wait after caging a pool to write off debt
    */
    function file(bytes32 ilk, bytes32 what, uint256 data) external auth {
        if (what == "tau") ilks[ilk].tau = data;
        else revert("D3MHub/file-unrecognized-param");

        emit File(ilk, what, data);
    }

    /**
        @notice update plan or pool addresses for D3M ilk.
        @dev msg.sender must be authorized.
        @param ilk  bytes32 of the D3M ilk to be updated
        @param what bytes32("pool"|"plan") or it will revert
        @param data address we are setting it to
    */
    function file(bytes32 ilk, bytes32 what, address data) external auth {
        require(vat.live() == 1, "D3MHub/no-file-during-shutdown");
        require(ilks[ilk].tic == 0, "D3MHub/pool-not-live");

        if (what == "pool") ilks[ilk].pool = ID3MPool(data);
        else if (what == "plan") ilks[ilk].plan = ID3MPlan(data);
        else revert("D3MHub/file-unrecognized-param");
        emit File(ilk, what, data);
    }

    // --- Deposit controls ---
    function _wind(bytes32 ilk, ID3MPool pool, uint256 amount) internal {
        // IMPORTANT: this function assumes Vat rate of this ilk will always be == 1 * RAY (no fees).
        // That's why this module converts normalized debt (art) to Vat DAI generated with a simple RAY multiplication or division
        // This module will have an unintended behaviour if rate is changed to some other value.
        if (amount == 0) {
            emit Wind(ilk, 0);
            return;
        }

        vat.slip(ilk, address(pool), int256(amount));
        vat.frob(ilk, address(pool), address(pool), address(this), int256(amount), int256(amount));
        // normalized debt == erc20 DAI (Vat rate for this ilk fixed to 1 RAY)
        daiJoin.exit(address(pool), amount);
        require(pool.deposit(amount), "D3MHub/deposit-failed");

        emit Wind(ilk, amount);
    }

    function _unwind(
                bytes32 ilk, 
                ID3MPool pool, 
                uint256 supplyReduction, // [wad]
                Mode mode, 
                uint256 assetBalance     // [wad]
             ) internal {
        // IMPORTANT: this function assumes Vat rate of this ilk will always be == 1 * RAY (no fees).
        // That's why it converts normalized debt (art) to Vat DAI generated with a simple RAY multiplication or division
        // This module will have an unintended behaviour if rate is changed to some other value.

        EndLike end_;
        uint256 daiDebt;
        if (mode == Mode.NORMAL) {
            // Normal mode or module just caged (no culled)
            // debt is obtained from CDP art
            (,daiDebt) = vat.urns(ilk, address(pool));
        } else if (mode == Mode.MODULE_CULLED) {
            // Module shutdown and culled
            // debt is obtained from free collateral owned by this contract
            // We rebalance the CDP after grabbing in `cull` so the gems represents
            // the debt at time of cull
            daiDebt = vat.gem(ilk, address(pool));
        } else {
            // MCD caged
            // debt is obtained from free collateral owned by the End module
            end_ = end;
            end_.skim(ilk, address(pool));
            daiDebt = vat.gem(ilk, address(end_));
        }

        uint256 availableAssets = pool.maxWithdraw();

        // Unwind amount is limited by how much:
        // - max reduction desired
        // - assets available
        // - dai debt tracked in vat (CDP or free)
        uint256 amount = _min(
                            _min(
                                _min(
                                    supplyReduction,
                                    availableAssets
                                ),
                                daiDebt
                            ),
                            MAXINT256
                         );

        // Determine the amount of fees to bring back
        uint256 fees = 0;
        if (assetBalance > daiDebt) {
            unchecked {
                fees = assetBalance - daiDebt;
            }

            if (amount + fees > availableAssets) {
                unchecked {
                    fees = availableAssets - amount;
                }
            }
        }

        if (amount == 0 && fees == 0) {
            emit Unwind(ilk, 0, 0);
            return;
        }

        // To save gas you can bring the fees back with the unwind
        uint256 total = amount + fees;
        require(pool.withdraw(total), "D3MHub/withdraw-failed");
        daiJoin.join(address(this), total);

        // normalized debt == erc20 DAI to pool (Vat rate for this ilk fixed to 1 RAY)

        if (mode == Mode.NORMAL) {
            vat.frob(ilk, address(pool), address(pool), address(this), -int256(amount), -int256(amount));
            vat.slip(ilk, address(pool), -int256(amount));
            vat.move(address(this), vow, fees * RAY);
        } else if (mode == Mode.MODULE_CULLED) {
            vat.slip(ilk, address(pool), -int256(amount));
            vat.move(address(this), vow, total * RAY);
        } else {
            // This can be done with the assumption that the price of 1 collateral unit equals 1 DAI.
            // That way we know that the prev End.skim call kept its gap[ilk] emptied as the CDP was always collateralized.
            // Otherwise we couldn't just simply take away the collateral from the End module as the next line will be doing.
            vat.slip(ilk, address(end_), -int256(amount));
            vat.move(address(this), vow, total * RAY);
        }

        emit Unwind(ilk, amount, fees);
    }

    /**
        @notice remove nope on daiJoin to kill hub
    */
    function nope() external auth {
        vat.nope(address(daiJoin));
    }

    // Ilk Getters
    /**
        @notice Return pool of an ilk
        @param ilk   bytes32 of the D3M ilk
        @return pool address of pool contract
    */
    function ilkPool(bytes32 ilk) external view returns (address) {
        return address(ilks[ilk].pool);
    }

    /**
        @notice Return plan of an ilk
        @param ilk   bytes32 of the D3M ilk
        @return plan address of plan contract
    */
    function ilkPlan(bytes32 ilk) external view returns (address) {
        return address(ilks[ilk].plan);
    }

    /**
        @notice Return tau of an ilk
        @param ilk  bytes32 of the D3M ilk
        @return tau sec until debt can be written off
    */
    function ilkTau(bytes32 ilk) external view returns (uint256) {
        return ilks[ilk].tau;
    }

    /**
        @notice Return culled status of an ilk
        @param ilk  bytes32 of the D3M ilk
        @return culled whether or not the d3m has been culled
    */
    function ilkCulled(bytes32 ilk) external view returns (uint256) {
        return ilks[ilk].culled;
    }

    /**
        @notice Return tic of an ilk
        @param ilk  bytes32 of the D3M ilk
        @return tic timestamp of when d3m is caged
    */
    function ilkTic(bytes32 ilk) external view returns (uint256) {
        return ilks[ilk].tic;
    }

    /**
        @notice Main function for updating a D3M position.
        Determines the current state and either winds or unwinds as necessary.
        @dev Winding the target position will be constrained by the Ilk debt
        ceiling, the overall DSS debt ceiling and the maximum deposit by the
        pool. Unwinding the target position will be constrained by the number
        of assets available to be withdrawn from the pool.
        @param ilk bytes32 of the D3M ilk name
    */
    function exec(bytes32 ilk) external lock {
        (uint256 Art, uint256 rate,, uint256 line,) = vat.ilks(ilk);
        require(rate == 1 * RAY, "D3MHub/rate-not-one");

        ID3MPool pool = ilks[ilk].pool;

        pool.preDebtChange("exec");
        uint256 currentAssets = pool.assetBalance();

        if (vat.live() == 0) {
            // MCD caged
            require(end.debt() == 0, "D3MHub/end-debt-already-set");
            require(ilks[ilk].culled == 0, "D3MHub/module-has-to-be-unculled-first");
            _unwind(
                ilk,
                pool,
                type(uint256).max,
                Mode.MCD_CAGED,
                currentAssets
            );
        } else if (ilks[ilk].tic != 0 || !pool.active() || !ilks[ilk].plan.active()) {
            // pool caged
            _unwind(
                ilk,
                pool,
                type(uint256).max,
                ilks[ilk].culled == 1
                ? Mode.MODULE_CULLED
                : Mode.NORMAL,
                currentAssets
            );
        } else {
            // Determine if it needs to unwind due to debt ceilings
            uint256 lineWad = line / RAY; // Round down to always be under the actual limit
            uint256 Line = vat.Line();
            uint256 debt = vat.debt();
            uint256 toUnwind;
            if (Art > lineWad) {
                unchecked {
                    toUnwind = Art - lineWad;
                }
            }
            if (debt > Line) {
                unchecked {
                    toUnwind = _max(toUnwind, _divup(debt - Line, RAY));
                }
            }

            // Determine if it needs to unwind due plan
            uint256 targetAssets = ilks[ilk].plan.getTargetAssets(currentAssets);
            if (targetAssets < currentAssets) {
                unchecked {
                    toUnwind = _max(toUnwind, currentAssets - targetAssets);
                }
            }

            if (toUnwind > 0) {
                _unwind(
                    ilk,
                    pool,
                    toUnwind,
                    Mode.NORMAL,
                    currentAssets
                );
            } else {
                uint256 toWind;
                // All the subtractions are safe as otherwise toUnwind is > 0
                unchecked {
                    toWind = _min(
                                _min(
                                    _min(
                                        _min(
                                            targetAssets - currentAssets,
                                            lineWad - Art
                                        ), 
                                        (Line - debt) / RAY
                                    ),
                                    pool.maxDeposit() // Determine if the pool limits our total deposits
                                ), 
                                MAXINT256
                            );
                }
                _wind(ilk, pool, toWind);
            }
        }

        pool.postDebtChange("exec");
    }

    /**
        @notice Collect interest and send to vow.
        Total collected will be constrained by the number of assets available to
        be withdrawn from the pool.
        @param ilk bytes32 of the D3M ilk name
    */
    function reap(bytes32 ilk) external lock {
        ID3MPool pool = ilks[ilk].pool;

        require(vat.live() == 1, "D3MHub/no-reap-during-shutdown");
        require(ilks[ilk].tic == 0, "D3MHub/pool-not-live");
        require(pool.active(), "D3MHub/pool-not-active");
        require(ilks[ilk].plan.active(), "D3MHub/plan-not-active");

        pool.preDebtChange("reap");
        uint256 assetBalance = pool.assetBalance();
        (, uint256 daiDebt) = vat.urns(ilk, address(pool));
        if (assetBalance > daiDebt) {
            uint256 fees;
            unchecked {
                fees = assetBalance - daiDebt;
            }
            fees = _min(fees, pool.maxWithdraw());
            require(pool.withdraw(fees), "D3MHub/withdraw-failed");
            daiJoin.join(vow, fees);
            emit Reap(ilk, fees);
        }
        pool.postDebtChange("reap");
    }

    /**
        @notice Allow Users to return vat gem for Pool Shares.
        This will only occur during Global Settlement when users receive
        collateral for their Dai.
        @param ilk bytes32 of the D3M ilk name
        @param usr address that should receive the shares from the pool
        @param wad amount of gems that the msg.sender is returning
    */
    function exit(bytes32 ilk, address usr, uint256 wad) external lock {
        require(wad <= MAXINT256, "D3MHub/overflow");
        vat.slip(ilk, msg.sender, -int256(wad));
        ID3MPool pool = ilks[ilk].pool;
        require(pool.transfer(usr, wad), "D3MHub/failed-transfer");
        emit Exit(ilk, usr, wad);
    }

    /**
        @notice Shutdown a pool.
        This starts the countdown to when the debt can be written off (cull).
        Once called, subsequent calls to `exec` will unwind as much of the
        position as possible.
        @dev msg.sender must be authorized.
        @param ilk bytes32 of the D3M ilk name
    */
    function cage(bytes32 ilk) external {
        require(vat.live() == 1, "D3MHub/no-cage-during-shutdown");
        require(ilks[ilk].tic == 0, "D3MHub/pool-already-caged");

        require(
            wards[msg.sender] == 1 ||
            ilks[ilk].pool.wild() ||
            ilks[ilk].plan.wild(),
        "D3MHub/no-auth-to-cage");

        ilks[ilk].tic = block.timestamp + ilks[ilk].tau;
        emit Cage(ilk);
    }

    /**
        @notice Write off the debt for a caged pool.
        This must occur while vat is live. Can be triggered by auth or
        after tau number of seconds has passed since the pool was caged.
        @dev This will send the pool's debt to the vow as sin and convert its
        collateral to gems.  There is a situation where another user has paid
        back some of the Pool's debt where ink != art in this case we rebalance
        so that vat.gems(pool) will represent the amount of debt sent to the vow.
        @param ilk bytes32 of the D3M ilk name
    */
    function cull(bytes32 ilk) external {
        require(vat.live() == 1, "D3MHub/no-cull-during-shutdown");

        uint256 tic = ilks[ilk].tic;
        require(tic > 0, "D3MHub/pool-live");

        require(tic <= block.timestamp || wards[msg.sender] == 1, "D3MHub/unauthorized-cull");

        uint256 culled = ilks[ilk].culled;
        require(culled == 0, "D3MHub/already-culled");

        ID3MPool pool = ilks[ilk].pool;

        (uint256 ink, uint256 art) = vat.urns(ilk, address(pool));
        require(ink <= MAXINT256, "D3MHub/overflow");
        require(art <= MAXINT256, "D3MHub/overflow");
        vat.grab(ilk, address(pool), address(pool), vow, -int256(ink), -int256(art));

        if (ink > art) {
            // We have more collateral than debt, so need to rebalance.
            // After cull the gems we grab above represent the debt to
            // unwind.
            unchecked {
                vat.slip(ilk, address(pool), -int256(ink - art));
            }
        }

        ilks[ilk].culled = 1;
        emit Cull(ilk, ink, art);
    }

    /**
        @notice Rollback Write-off (cull) if General Shutdown happened.
        This function is required to have the collateral back in the vault so it
        can be taken by End module and eventually be shared to DAI holders (as
        any other collateral) or maybe even unwinded.
        @dev This pulls gems from the pool and reopens the urn with the gem
        amount of ink/art.
        @param ilk bytes32 of the D3M ilk name
    */
    function uncull(bytes32 ilk) external {
        ID3MPool pool = ilks[ilk].pool;

        require(ilks[ilk].culled == 1, "D3MHub/not-prev-culled");
        require(vat.live() == 0, "D3MHub/no-uncull-normal-operation");

        address vow_ = vow;
        uint256 wad = vat.gem(ilk, address(pool));
        require(wad <= MAXINT256, "D3MHub/overflow");
        vat.suck(vow_, vow_, wad * RAY); // This needs to be done to make sure we can deduct sin[vow] and vice in the next call
        vat.grab(ilk, address(pool), address(pool), vow_, int256(wad), int256(wad));

        ilks[ilk].culled = 0;
        emit Uncull(ilk, wad);
    }

    /**
        @notice Emergency Quit Everything.
        Transfer all the shares and either wipe out the gems (culled situation)
        or fork the urn to the recipient.
        @dev If called while not culled, it will require who to hope on the Hub
        contract in the Vat.
        @param ilk bytes32 of the D3M ilk name
        @param who address of who will receive the shares and possibly the urn
    */
    function quit(bytes32 ilk, address who) external lock auth {
        require(vat.live() == 1, "D3MHub/no-quit-during-shutdown");

        ID3MPool pool = ilks[ilk].pool;

        // Send all gem in the contract to who
        require(pool.transferAll(who), "D3MHub/failed-transfer");

        if (ilks[ilk].culled == 1) {
            // Culled - just zero out the gems
            uint256 wad = vat.gem(ilk, address(pool));
            require(wad <= MAXINT256, "D3MHub/overflow");
            vat.slip(ilk, address(pool), -int256(wad));
        } else {
            // Regular operation - transfer the debt position (requires who to accept the transfer)
            (uint256 ink, uint256 art) = vat.urns(ilk, address(pool));
            require(ink <= MAXINT256, "D3MHub/overflow");
            require(art <= MAXINT256, "D3MHub/overflow");
            vat.fork(ilk, address(pool), who, int256(ink), int256(art));
        }
        emit Quit(ilk, who);
    }
}
