import { toNano } from '@ton/core';
import { DiceContract } from '../wrappers/DiceContract';
import { NetworkProvider } from '@ton/blueprint';

export async function run(provider: NetworkProvider) {
    const diceContract = provider.open(await DiceContract.fromInit());

    await diceContract.send(
        provider.sender(),
        {
            value: toNano('0.05'),
        },
        {
            $$type: 'Deploy',
            queryId: 0n,
        }
    );

    await provider.waitForDeploy(diceContract.address);

    // run methods on `diceContract`
}
