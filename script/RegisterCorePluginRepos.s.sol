// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.17;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

import {PluginRepoFactory} from "@aragon/osx/framework/plugin/repo/PluginRepoFactory.sol";
import {PluginRepoRegistry} from "@aragon/osx/framework/plugin/repo/PluginRepoRegistry.sol";
import {PluginRepo} from "@aragon/osx/framework/plugin/repo/PluginRepo.sol";

import {AdminSetup} from "@aragon/admin-plugin/AdminSetup.sol";
import {MultisigSetup} from "@aragon/multisig-plugin/MultisigSetup.sol";
import {TokenVotingSetup} from "@aragon/token-voting-plugin/TokenVotingSetup.sol";
import {GovernanceERC20} from "@aragon/token-voting-plugin/erc20/GovernanceERC20.sol";
import {GovernanceWrappedERC20} from "@aragon/token-voting-plugin/erc20/GovernanceWrappedERC20.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {StagedProposalProcessorSetup} from "@aragon/staged-proposal-processor-plugin/StagedProposalProcessorSetup.sol";

/// @notice Deploy only the core plugin *setup* contracts and register the plugin repos on an already deployed OSx stack.
/// @dev Uses an existing PluginRepoFactory address; the factory must already have REGISTER_PLUGIN_REPO permission on the registry.
contract RegisterCorePluginRepos is Script {
    using stdJson for string;

    // Default metadata URIs (same defaults as in Deploy.s.sol)
    string DEFAULT_ADMIN_RELEASE_METADATA = "ipfs://bafkreifbwooo3h36htzscftwm3kouoktcvkqyhaxluodo6xkyprnon3r54";
    string DEFAULT_ADMIN_BUILD_METADATA = "ipfs://bafkreifijshftf47q5mtoibfvwkzv42reqf4uddi46i7kcblt6bpsvgii4";
    string DEFAULT_MULTISIG_RELEASE_METADATA = "ipfs://bafkreiesxfvwf7qphbpw2epmabrrz2alwo66fso7tjx3cbt63k4xzec3ma";
    string DEFAULT_MULTISIG_BUILD_METADATA = "ipfs://bafkreiaipjj2ryy2ui77crwmgbamjkmr6xbdvrviylh4z4kf54sq2etvgu";
    string DEFAULT_TOKEN_VOTING_RELEASE_METADATA = "ipfs://QmWjZArvePnMPgbfKAMW3TidbqHEy68UV6SvRBhiaygGta";
    string DEFAULT_TOKEN_VOTING_BUILD_METADATA = "ipfs://QmfXUy5Lc4iqg8DvgWdSSD2ZhCmCGvE2WTdWYFE9sosCRc";
    string DEFAULT_SPP_RELEASE_METADATA = "ipfs://bafkreif23p6yw325rkwwlhgkudiasvq64lonqmfnt7ls5ksfam5hedcb4m";
    string DEFAULT_SPP_BUILD_METADATA = "ipfs://bafkreifia6hhz7klfbaqawd4vcplkoiesycbmrf5c2x24zfuivyn35mfsu";

    // Deployed in this script
    AdminSetup adminSetup;
    MultisigSetup multisigSetup;
    GovernanceERC20 governanceERC20Base;
    GovernanceWrappedERC20 governanceWrappedERC20Base;
    TokenVotingSetup tokenVotingSetup;
    StagedProposalProcessorSetup stagedProposalProcessorSetup;

    // Created via existing PluginRepoFactory
    PluginRepo adminRepo;
    PluginRepo multisigRepo;
    PluginRepo tokenVotingRepo;
    PluginRepo sppRepo;

    modifier broadcast() {
        uint256 privKey = vm.envUint("DEPLOYMENT_PRIVATE_KEY");
        vm.startBroadcast(privKey);
        console.log("- Deployer:", vm.addr(privKey));
        console.log("- Chain ID:", block.chainid);
        _;
        vm.stopBroadcast();
    }

    function run() external broadcast {
        address pluginRepoFactoryAddress = vm.envAddress("EXISTING_PLUGIN_REPO_FACTORY");
        address maintainer = vm.envAddress("EXISTING_MANAGEMENT_DAO");

        PluginRepoFactory pluginRepoFactory = PluginRepoFactory(pluginRepoFactoryAddress);
        PluginRepoRegistry pluginRepoRegistry = pluginRepoFactory.pluginRepoRegistry();

        console.log("Existing OSx:");
        console.log("- PluginRepoFactory:", pluginRepoFactoryAddress);
        console.log("- PluginRepoRegistry:", address(pluginRepoRegistry));
        console.log("- PluginRepoBase:", pluginRepoFactory.pluginRepoBase());
        console.log("- Maintainer (Management DAO):", maintainer);
        console.log();

        deployPluginSetups();
        createRepos(pluginRepoFactory, pluginRepoRegistry, maintainer);

        printSummary(pluginRepoFactory, pluginRepoRegistry, maintainer);

        if (!vm.envOr("SIMULATE", false)) {
            writeJsonAddresses(pluginRepoFactory, pluginRepoRegistry, maintainer);
        }
    }

    function deployPluginSetups() internal {
        adminSetup = new AdminSetup();
        multisigSetup = new MultisigSetup();

        governanceERC20Base = new GovernanceERC20();
        governanceWrappedERC20Base = new GovernanceWrappedERC20(IERC20Upgradeable(address(0)), "", "");
        tokenVotingSetup = new TokenVotingSetup(governanceERC20Base, governanceWrappedERC20Base);

        stagedProposalProcessorSetup = new StagedProposalProcessorSetup();

        console.log("Deployed plugin setup contracts:");
        console.log("- AdminSetup:", address(adminSetup));
        console.log("- MultisigSetup:", address(multisigSetup));
        console.log("- GovernanceERC20 (base):", address(governanceERC20Base));
        console.log("- GovernanceWrappedERC20 (base):", address(governanceWrappedERC20Base));
        console.log("- TokenVotingSetup:", address(tokenVotingSetup));
        console.log("- StagedProposalProcessorSetup:", address(stagedProposalProcessorSetup));
        console.log();
    }

    function createRepos(
        PluginRepoFactory pluginRepoFactory,
        PluginRepoRegistry pluginRepoRegistry,
        address maintainer
    ) internal {
        string memory adminSubdomain = vm.envOr("ADMIN_PLUGIN_SUBDOMAIN", string("admin"));
        string memory multisigSubdomain = vm.envOr("MULTISIG_PLUGIN_SUBDOMAIN", string("multisig"));
        string memory tokenVotingSubdomain = vm.envOr("TOKEN_VOTING_PLUGIN_SUBDOMAIN", string("token-voting"));
        string memory sppSubdomain = vm.envOr("STAGED_PROPOSAL_PROCESSOR_PLUGIN_SUBDOMAIN", string("spp"));

        bool ensSupported = address(pluginRepoRegistry.subdomainRegistrar()) != address(0);
        if (!ensSupported) {
            console.log("ENS not supported on this network; registering repos with empty subdomain to skip ENS.");
            adminSubdomain = "";
            multisigSubdomain = "";
            tokenVotingSubdomain = "";
            sppSubdomain = "";
        }

        string memory adminReleaseMetadata = vm.envOr("ADMIN_PLUGIN_RELEASE_METADATA_URI", DEFAULT_ADMIN_RELEASE_METADATA);
        string memory adminBuildMetadata = vm.envOr("ADMIN_PLUGIN_BUILD_METADATA_URI", DEFAULT_ADMIN_BUILD_METADATA);
        string memory multisigReleaseMetadata = vm.envOr(
            "MULTISIG_PLUGIN_RELEASE_METADATA_URI",
            DEFAULT_MULTISIG_RELEASE_METADATA
        );
        string memory multisigBuildMetadata = vm.envOr("MULTISIG_PLUGIN_BUILD_METADATA_URI", DEFAULT_MULTISIG_BUILD_METADATA);
        string memory tokenVotingReleaseMetadata = vm.envOr(
            "TOKEN_VOTING_PLUGIN_RELEASE_METADATA_URI",
            DEFAULT_TOKEN_VOTING_RELEASE_METADATA
        );
        string memory tokenVotingBuildMetadata = vm.envOr(
            "TOKEN_VOTING_PLUGIN_BUILD_METADATA_URI",
            DEFAULT_TOKEN_VOTING_BUILD_METADATA
        );
        string memory sppReleaseMetadata = vm.envOr(
            "STAGED_PROPOSAL_PROCESSOR_PLUGIN_RELEASE_METADATA_URI",
            DEFAULT_SPP_RELEASE_METADATA
        );
        string memory sppBuildMetadata = vm.envOr(
            "STAGED_PROPOSAL_PROCESSOR_PLUGIN_BUILD_METADATA_URI",
            DEFAULT_SPP_BUILD_METADATA
        );

        console.log("Registering core plugin repos (createPluginRepoWithFirstVersion)...");

        adminRepo = pluginRepoFactory.createPluginRepoWithFirstVersion(
            adminSubdomain,
            address(adminSetup),
            maintainer,
            bytes(adminReleaseMetadata),
            bytes(adminBuildMetadata)
        );

        multisigRepo = pluginRepoFactory.createPluginRepoWithFirstVersion(
            multisigSubdomain,
            address(multisigSetup),
            maintainer,
            bytes(multisigReleaseMetadata),
            bytes(multisigBuildMetadata)
        );

        tokenVotingRepo = pluginRepoFactory.createPluginRepoWithFirstVersion(
            tokenVotingSubdomain,
            address(tokenVotingSetup),
            maintainer,
            bytes(tokenVotingReleaseMetadata),
            bytes(tokenVotingBuildMetadata)
        );

        sppRepo = pluginRepoFactory.createPluginRepoWithFirstVersion(
            sppSubdomain,
            address(stagedProposalProcessorSetup),
            maintainer,
            bytes(sppReleaseMetadata),
            bytes(sppBuildMetadata)
        );

        console.log("Registered PluginRepo proxies:");
        console.log("- AdminRepo:", address(adminRepo));
        console.log("- MultisigRepo:", address(multisigRepo));
        console.log("- TokenVotingRepo:", address(tokenVotingRepo));
        console.log("- SPPRepo:", address(sppRepo));
        console.log();
    }

    function printSummary(
        PluginRepoFactory pluginRepoFactory,
        PluginRepoRegistry pluginRepoRegistry,
        address maintainer
    ) internal view {
        console.log("Summary (copy these addresses):");
        console.log("- PluginRepoFactory:", address(pluginRepoFactory));
        console.log("- PluginRepoRegistry:", address(pluginRepoRegistry));
        console.log("- PluginRepoBase:", pluginRepoFactory.pluginRepoBase());
        console.log("- Management DAO (maintainer):", maintainer);
        console.log("- AdminSetup:", address(adminSetup));
        console.log("- MultisigSetup:", address(multisigSetup));
        console.log("- GovernanceERC20 base:", address(governanceERC20Base));
        console.log("- GovernanceWrappedERC20 base:", address(governanceWrappedERC20Base));
        console.log("- TokenVotingSetup:", address(tokenVotingSetup));
        console.log("- SPPSetup:", address(stagedProposalProcessorSetup));
        console.log("- AdminRepo:", address(adminRepo));
        console.log("- MultisigRepo:", address(multisigRepo));
        console.log("- TokenVotingRepo:", address(tokenVotingRepo));
        console.log("- SPPRepo:", address(sppRepo));
        console.log();
    }

    function writeJsonAddresses(
        PluginRepoFactory pluginRepoFactory,
        PluginRepoRegistry pluginRepoRegistry,
        address maintainer
    ) internal {
        // Build nested objects first.
        string memory existingObj = "existing";
        existingObj.serialize("managementDao", maintainer);
        existingObj.serialize("pluginRepoFactory", address(pluginRepoFactory));
        existingObj.serialize("pluginRepoRegistry", address(pluginRepoRegistry));
        existingObj = existingObj.serialize("pluginRepoBase", pluginRepoFactory.pluginRepoBase());

        string memory setupsObj = "setups";
        setupsObj.serialize("adminSetup", address(adminSetup));
        setupsObj.serialize("multisigSetup", address(multisigSetup));
        setupsObj.serialize("governanceErc20Base", address(governanceERC20Base));
        setupsObj.serialize("governanceWrappedErc20Base", address(governanceWrappedERC20Base));
        setupsObj.serialize("tokenVotingSetup", address(tokenVotingSetup));
        setupsObj = setupsObj.serialize("stagedProposalProcessorSetup", address(stagedProposalProcessorSetup));

        string memory reposObj = "repos";
        reposObj.serialize("adminRepo", address(adminRepo));
        reposObj.serialize("multisigRepo", address(multisigRepo));
        reposObj.serialize("tokenVotingRepo", address(tokenVotingRepo));
        reposObj = reposObj.serialize("stagedProposalProcessorRepo", address(sppRepo));

        // Root object.
        string memory root = "root";
        root.serialize("networkName", vm.envString("NETWORK_NAME"));
        root.serialize("chainId", block.chainid);
        root.serialize("existing", existingObj);
        root.serialize("setups", setupsObj);
        root = root.serialize("repos", reposObj);

        string memory filePath = string.concat(
            vm.projectRoot(),
            "/artifacts/core-plugin-repos-",
            vm.envString("NETWORK_NAME"),
            "-",
            Strings.toString(block.timestamp),
            ".json"
        );

        root.write(filePath);
        console.log("Deployment addresses written to", filePath);
    }
}
