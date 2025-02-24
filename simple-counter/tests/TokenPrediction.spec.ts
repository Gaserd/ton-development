import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano } from '@ton/core';
import { TokenPrediction } from '../wrappers/TokenPrediction';
import '@ton/test-utils';

describe('TokenPrediction', () => {
    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let tokenPrediction: SandboxContract<TokenPrediction>;

    beforeEach(async () => {
        blockchain = await Blockchain.create();

        tokenPrediction = blockchain.openContract(await TokenPrediction.fromInit());
        deployer = await blockchain.treasury('deployer');

        const deployResult = await tokenPrediction.send(
            deployer.getSender(),
            {
                value: toNano('0.05'),
            },
            {
                $$type: 'Deploy',
                queryId: 0n,
            }
        );

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: tokenPrediction.address,
            deploy: true,
            success: true,
        });
    });

    it('create round', async () => {
        // the check is done inside beforeEach
        // blockchain and tokenPrediction are ready to use
    });
});
