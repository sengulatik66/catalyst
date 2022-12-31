//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.9;

interface IbcDispatcher {
    function registerPort() external;

    function sendIbcPacket(
        bytes32 channelId,
        bytes calldata payload,
        uint64 timeoutBlockHeight
    ) external;
}