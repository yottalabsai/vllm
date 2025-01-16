import json

import matplotlib.pyplot as plt
import pandas as pd

if __name__ == "__main__":

    data = []
    for name in ['disagg_prefill_http', 'disagg_prefill_zmq']:
        for qps in [2, 4, 6, 8, 10, 12]:
            with open(f"results/{name}-qps-{qps}.json") as f:
                x = json.load(f)
                x['name'] = name
                x['qps'] = qps
                data.append(x)

    df = pd.DataFrame.from_dict(data)
    dis_http_df = df[df['name'] == 'disagg_prefill_http']
    dis_zmq_df = df[df['name'] == 'disagg_prefill_zmq']

    plt.style.use('bmh')
    plt.rcParams['font.size'] = 20

    for key in [
            'mean_ttft_ms', 'median_ttft_ms', 'p99_ttft_ms', 'mean_itl_ms',
            'median_itl_ms', 'p99_itl_ms'
    ]:

        fig, ax = plt.subplots(figsize=(11, 7))
        plt.plot(dis_http_df['qps'],
                 dis_http_df[key],
                 label='disagg_prefill_http',
                 marker='o',
                 linewidth=4)
        plt.plot(dis_zmq_df['qps'],
                 dis_zmq_df[key],
                 label='disagg_prefill_zmq',
                 marker='o',
                 linewidth=4)
        ax.legend()

        ax.set_xlabel('QPS')
        ax.set_ylabel(key)
        ax.set_ylim(bottom=0)
        fig.savefig(f'results/{key}.png')
        plt.close(fig)
