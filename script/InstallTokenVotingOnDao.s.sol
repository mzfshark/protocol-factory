// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.17;

import {Script, console} from "forge-std/Script.sol";

import {PluginRepo} from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";
import {PluginSetupProcessor} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessor.sol";
import {PluginSetupRef} from "@aragon/osx/framework/plugin/setup/PluginSetupProcessorHelpers.sol";

import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";
import {IPluginSetup} from "@aragon/osx-commons-contracts/src/plugin/setup/IPluginSetup.sol";

import {TokenVotingSetup} from "@aragon/token-voting-plugin/TokenVotingSetup.sol";
import {GovernanceERC20} from "@aragon/token-voting-plugin/erc20/GovernanceERC20.sol";
import {MajorityVotingBase} from "@aragon/token-voting-plugin/base/MajorityVotingBase.sol";

interface IPermissionManager {
    function grant(address where, address who, bytes32 permissionId) external;
    function revoke(address where, address who, bytes32 permissionId) external;
}

/// @notice Instala TokenVoting em um DAO já criado, usando PluginSetupProcessor.
/// @dev Requer que o caller tenha ROOT no DAO para grant/revoke temporários.
contract InstallTokenVotingOnDao is Script {
    bytes32 private constant ROOT_PERMISSION_ID = keccak256("ROOT_PERMISSION");

    modifier broadcast() {
        uint256 privKey = vm.envUint("DEPLOYMENT_PRIVATE_KEY");
        vm.startBroadcast(privKey);
        console.log("- Deployer:", vm.addr(privKey));
        console.log("- Chain ID:", block.chainid);
        _;
        vm.stopBroadcast();
    }

    function run() external broadcast {
        address dao = vm.envAddress("TARGET_DAO");
        address pspAddress = vm.envAddress("PLUGIN_SETUP_PROCESSOR");
        address tokenVotingRepoAddress = vm.envAddress("TOKEN_VOTING_REPO");

        address deployer = vm.addr(vm.envUint("DEPLOYMENT_PRIVATE_KEY"));

        uint8 release = uint8(vm.envOr("TOKEN_VOTING_RELEASE", uint256(1)));
        uint16 build = uint16(vm.envOr("TOKEN_VOTING_BUILD", uint256(1)));

        // Voting settings
        uint8 votingMode = uint8(vm.envOr("VOTING_MODE", uint256(0)));
        uint32 supportThreshold = uint32(vm.envOr("SUPPORT_THRESHOLD", uint256(500_000))); // 50%
        uint32 minParticipation = uint32(vm.envOr("MIN_PARTICIPATION", uint256(0)));
        uint64 minDuration = uint64(vm.envOr("MIN_DURATION", uint256(3600))); // 1h
        uint256 minProposerVotingPower = vm.envOr("MIN_PROPOSER_VOTING_POWER", uint256(0));

        // Token settings
        address tokenAddr = vm.envOr("TOKEN_ADDRESS", address(0));
        string memory tokenName = vm.envOr("TOKEN_NAME", string("Governance Token"));
        string memory tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("GOV"));

        // Mint settings (somente para token novo)
        address mintReceiver = vm.envOr("MINT_RECEIVER", vm.addr(vm.envUint("DEPLOYMENT_PRIVATE_KEY")));
        uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(1_000_000 ether));

        // Target config
        address target = vm.envOr("TARGET_EXECUTOR", dao);
        uint8 operation = uint8(vm.envOr("TARGET_OPERATION", uint256(0))); // 0=Call, 1=DelegateCall

        uint256 minApprovals = vm.envOr("MIN_APPROVALS", uint256(0));
        string memory pluginMetadataUri = vm.envOr("PLUGIN_METADATA_URI", string(""));

        console.log("Installing TokenVoting on DAO:");
        console.log("- DAO:", dao);
        console.log("- PSP:", pspAddress);
        console.log("- TokenVotingRepo:", tokenVotingRepoAddress);
        console.log("- Version tag:", release, ".", uint256(build));

        PluginSetupProcessor psp = PluginSetupProcessor(pspAddress);
        PluginRepo repo = PluginRepo(tokenVotingRepoAddress);
        IPermissionManager permissionManager = IPermissionManager(dao);

        PluginRepo.Tag memory tag = PluginRepo.Tag({release: release, build: build});
        PluginRepo.Version memory version = repo.getVersion(tag);

        console.log("- TokenVotingSetup (from repo):", version.pluginSetup);

        MajorityVotingBase.VotingSettings memory votingSettings = MajorityVotingBase.VotingSettings({
            votingMode: MajorityVotingBase.VotingMode(votingMode),
            supportThreshold: supportThreshold,
            minParticipation: minParticipation,
            minDuration: minDuration,
            minProposerVotingPower: minProposerVotingPower
        });

        TokenVotingSetup.TokenSettings memory tokenSettings = TokenVotingSetup.TokenSettings({
            addr: tokenAddr,
            name: tokenName,
            symbol: tokenSymbol
        });

        GovernanceERC20.MintSettings memory mintSettings;
        if (tokenAddr == address(0)) {
            mintSettings.receivers = new address[](1);
            mintSettings.amounts = new uint256[](1);
            mintSettings.receivers[0] = mintReceiver;
            mintSettings.amounts[0] = mintAmount;
        } else {
            mintSettings.receivers = new address[](0);
            mintSettings.amounts = new uint256[](0);
        }

        IPlugin.TargetConfig memory targetConfig = IPlugin.TargetConfig({
            target: target,
            operation: IPlugin.Operation(operation)
        });

        address[] memory excludedAccounts = new address[](0);
        bytes memory pluginMetadata = bytes(pluginMetadataUri);

        // Must match TokenVotingSetup.decodeInstallationParameters
        bytes memory data = abi.encode(
            votingSettings,
            tokenSettings,
            mintSettings,
            targetConfig,
            minApprovals,
            pluginMetadata,
            excludedAccounts
        );

        // Grant temporários (igual DAOFactory)
        permissionManager.grant(dao, pspAddress, ROOT_PERMISSION_ID);
        permissionManager.grant(pspAddress, deployer, psp.APPLY_INSTALLATION_PERMISSION_ID());

        // Prepare
        PluginSetupRef memory setupRef = PluginSetupRef({versionTag: tag, pluginSetupRepo: repo});

        (address plugin, IPluginSetup.PreparedSetupData memory prepared) = psp.prepareInstallation(
            dao,
            PluginSetupProcessor.PrepareInstallationParams({pluginSetupRef: setupRef, data: data})
        );

        bytes32 helpersHash = keccak256(abi.encode(prepared.helpers));

        console.log("- Prepared plugin:", plugin);
        console.log("- HelpersHash:");
        console.logBytes32(helpersHash);

        // Apply
        psp.applyInstallation(
            dao,
            PluginSetupProcessor.ApplyInstallationParams({
                pluginSetupRef: setupRef,
                plugin: plugin,
                permissions: prepared.permissions,
                helpersHash: helpersHash
            })
        );

        // Revoke temporários
        permissionManager.revoke(dao, pspAddress, ROOT_PERMISSION_ID);
        permissionManager.revoke(pspAddress, deployer, psp.APPLY_INSTALLATION_PERMISSION_ID());

        console.log("Done.");
    }
}
