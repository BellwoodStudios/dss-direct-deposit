// SPDX-FileCopyrightText: © 2022 Dai Foundation <www.daifoundation.org>
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

import {DssTest} from "dss-test/DssTest.sol";
import {DaiLike, CanLike, D3mHubLike} from "../interfaces/interfaces.sol";

import "../../pools/ID3MPool.sol";

interface Hevm {
    function warp(uint256) external;

    function store(
        address,
        bytes32,
        bytes32
    ) external;

    function load(address, bytes32) external view returns (bytes32);

    function roll(uint256) external;
}

interface VatLike {
    function live() external view returns (uint256);
    function hope(address) external;
    function nope(address) external;
}

contract D3MPoolBase is ID3MPool {

    address public hub;

    VatLike public immutable vat;

    DaiLike public immutable asset; // Dai

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }
    modifier auth {
        require(wards[msg.sender] == 1, "D3MPoolBase/not-authorized");
        _;
    }

    modifier onlyHub {
        require(msg.sender == hub, "D3MPoolBase/only-hub");
        _;
    }

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    constructor(address hub_, address dai_) {
        asset = DaiLike(dai_);

        hub = hub_;
        vat = VatLike(D3mHubLike(hub_).vat());

        CanLike(D3mHubLike(hub_).vat()).hope(hub_);

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    function file(bytes32 what, address data) external auth {
        require(vat.live() == 1, "D3MPoolBase/no-file-during-shutdown");
        if (what == "hub") {
            vat.nope(hub);
            hub = data;
            vat.hope(data);
        }
        else revert("D3MPoolBase/file-unrecognized-param");
    }

    function deposit(uint256 wad) external onlyHub override {}

    function withdraw(uint256 wad) external onlyHub override {}

    function exit(address dst, uint256 wad) onlyHub external override {}

    function preDebtChange() external override {}

    function postDebtChange() external override {}

    function assetBalance() external view override returns (uint256) {}

    function quit(address dst) external auth view override {
        dst;
        require(vat.live() == 1, "D3MPoolBase/no-quit-during-shutdown");
    }

    function maxDeposit() external view override returns (uint256) {}

    function maxWithdraw() external view override returns (uint256) {}

    function redeemable() external override pure returns(address) {
        return address(0);
    }
}

contract FakeVat {
    uint256 public live = 1;
    mapping(address => mapping (address => uint)) public can;
    function cage() external { live = 0; }
    function hope(address usr) external { can[msg.sender][usr] = 1; }
    function nope(address usr) external { can[msg.sender][usr] = 0; }
}

contract FakeEnd {
    uint256 internal Art_;

    function setArt(uint256 _Art) external {
        Art_ = _Art;
    }

    function Art(bytes32) external view returns (uint256) {
        return Art_;
    }
}

contract FakeHub {
    address public immutable vat;
    FakeEnd public immutable end = new FakeEnd();

    constructor(address vat_) {
        vat = vat_;
    }
}

contract D3MPoolBaseTest is DssTest {
    string contractName;

    DaiLike dai;

    address d3mTestPool;
    address hub;
    address vat;

    function setUp() public virtual {
        contractName = "D3MPoolBase";

        dai = DaiLike(0x6B175474E89094C44Da98b954EedeAC495271d0F);

        vat = address(new FakeVat());

        hub = address(new FakeHub(vat));

        d3mTestPool = address(new D3MPoolBase(hub, address(dai)));
    }

    function _giveTokens(DaiLike token, uint256 amount) internal {
        // Edge case - balance is already set for some reason
        if (token.balanceOf(address(this)) == amount) return;

        for (int256 i = 0; i < 100; i++) {
            // Scan the storage for the balance storage slot
            bytes32 prevValue = vm.load(
                address(token),
                keccak256(abi.encode(address(this), uint256(i)))
            );
            vm.store(
                address(token),
                keccak256(abi.encode(address(this), uint256(i))),
                bytes32(amount)
            );
            if (token.balanceOf(address(this)) == amount) {
                // Found it
                return;
            } else {
                // Keep going after restoring the original value
                vm.store(
                    address(token),
                    keccak256(abi.encode(address(this), uint256(i))),
                    prevValue
                );
            }
        }

        // We have failed if we reach here
        assertTrue(false);
    }

    function test_sets_creator_as_ward() public {
        assertEq(D3MPoolBase(d3mTestPool).wards(address(this)), 1);
    }

    function test_hopes_on_hub() public {
        assertEq(CanLike(vat).can(d3mTestPool, hub), 1);
    }

    function test_can_rely_deny() public {
        assertEq(D3MPoolBase(d3mTestPool).wards(address(123)), 0);

        D3MPoolBase(d3mTestPool).rely(address(123));

        assertEq(D3MPoolBase(d3mTestPool).wards(address(123)), 1);

        D3MPoolBase(d3mTestPool).deny(address(123));

        assertEq(D3MPoolBase(d3mTestPool).wards(address(123)), 0);
    }

    function test_cannot_rely_no_auth() public {
        D3MPoolBase(d3mTestPool).deny(address(this));

        assertRevert(address(d3mTestPool), abi.encodeWithSignature("rely(address)", address(123)), string(abi.encodePacked(contractName, "/not-authorized")));
    }

    function test_cannot_deny_no_auth() public {
        D3MPoolBase(d3mTestPool).deny(address(this));

        assertRevert(address(d3mTestPool), abi.encodeWithSignature("deny(address)", address(123)), string(abi.encodePacked(contractName, "/not-authorized")));
    }

    function test_can_file_hub() public {
        address newHub = address(new FakeHub(vat));
        assertEq(CanLike(vat).can(d3mTestPool, hub), 1);
        assertEq(CanLike(vat).can(d3mTestPool, newHub), 0);
        D3MPoolBase(d3mTestPool).file("hub", newHub);
        assertEq(CanLike(vat).can(d3mTestPool, hub), 0);
        assertEq(CanLike(vat).can(d3mTestPool, newHub), 1);
    }

    function test_cannot_file_hub_no_auth() public {
        D3MPoolBase(d3mTestPool).deny(address(this));

        assertRevert(address(d3mTestPool), abi.encodeWithSignature("file(bytes32,address)", bytes32("hub"), address(123)), string(abi.encodePacked(contractName, "/not-authorized")));
    }

    function test_cannot_file_hub_vat_caged() public {
        FakeVat(vat).cage();

        assertRevert(address(d3mTestPool), abi.encodeWithSignature("file(bytes32,address)", bytes32("hub"), address(123)), string(abi.encodePacked(contractName, "/no-file-during-shutdown")));
    }

    function test_cannot_file_unknown_param() public {
        assertRevert(address(d3mTestPool), abi.encodeWithSignature("file(bytes32,address)", bytes32("fail"), address(123)), string(abi.encodePacked(contractName, "/file-unrecognized-param")));
    }

    function test_deposit_not_hub() public {
        assertRevert(address(d3mTestPool), abi.encodeWithSignature("deposit(uint256)", uint256(1)), string(abi.encodePacked(contractName, "/only-hub")));
    }

    function test_withdraw_not_hub() public {
        assertRevert(address(d3mTestPool), abi.encodeWithSignature("withdraw(uint256)", uint256(1)), string(abi.encodePacked(contractName, "/only-hub")));
    }

    function test_exit_not_hub() public {
        assertRevert(address(d3mTestPool), abi.encodeWithSignature("exit(address,uint256)", address(this), uint256(0)), string(abi.encodePacked(contractName, "/only-hub")));
    }

    function test_quit_no_auth() public {
        D3MPoolBase(d3mTestPool).deny(address(this));
        assertRevert(address(d3mTestPool), abi.encodeWithSignature("quit(address)", address(this)), string(abi.encodePacked(contractName, "/not-authorized")));
    }

    function test_quit_vat_caged() public {
        FakeVat(vat).cage();
        assertRevert(address(d3mTestPool), abi.encodeWithSignature("quit(address)", address(this)), string(abi.encodePacked(contractName, "/no-quit-during-shutdown")));
    }

    function test_implements_preDebtChange() public {
        D3MPoolBase(d3mTestPool).preDebtChange();
    }

    function test_implements_postDebtChange() public {
        D3MPoolBase(d3mTestPool).postDebtChange();
    }
}
