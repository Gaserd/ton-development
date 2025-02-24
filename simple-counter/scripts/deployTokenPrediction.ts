import { toNano } from '@ton/core';
import { TokenPrediction } from '../wrappers/TokenPrediction';
import { NetworkProvider } from '@ton/blueprint';

export async function run(provider: NetworkProvider) {
    const tokenPrediction = provider.open(await TokenPrediction.fromInit());

    await tokenPrediction.send(
        provider.sender(),
        {
            value: toNano('0.05'),
        },
        {
            $$type: 'Deploy',
            queryId: 0n,
        }
    );

    await provider.waitForDeploy(tokenPrediction.address);

    // run methods on `tokenPrediction`
}
