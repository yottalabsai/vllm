import json
import os

import matplotlib.pyplot as plt
import pandas as pd


def draw_png(keys, df_list, label_col, path):
    plt.style.use('bmh')
    plt.rcParams['font.size'] = 20
    if not os.path.exists(path):
        os.makedirs(path)

    unique_labels = df_list[label_col].unique()
    print(unique_labels)
    grouped_df = df_list.groupby(label_col)
    for key in keys:
        fig, ax = plt.subplots(figsize=(11, 7))
        for label_col, group in grouped_df:
            print(label_col)
            print(group)
            plt.plot(group['qps'],
                 group[key],
                 label=label_col,
                 marker='o',
                 linewidth=4)
        ax.legend()
        ax.set_xlabel('QPS')
        ax.set_ylabel(key)
        ax.set_ylim(bottom=0)
        fig.savefig(f'{path}/{key}.png')
        plt.close(fig)


if __name__ == "__main__":
    data = []
    names = ['disagg_prefill_http', 'disagg_prefill_zmq', 'chunked_prefill']
    for name in names:
        for qps in [12, 24, 48, 96]:
            for index in range(1, 4):
                with open(f"results/{name}_qps_{qps}_{index}.json") as f:
                    x = json.load(f)
                    x['name'] = name
                    x['index'] = index
                    x['name_index'] = f'{name}_{index}'
                    x['qps'] = qps
                    data.append(x)

    df = pd.DataFrame.from_dict(data)
    keys = [
            'mean_ttft_ms', 'median_ttft_ms', 'p99_ttft_ms', 'mean_itl_ms',
            'median_itl_ms', 'p99_itl_ms'
    ]

    columns_to_keep = ['name', 'index', 'name_index','qps']
    columns_to_keep.extend(keys)
    df = df[columns_to_keep]


    for name in names:
        name_df = df[df['name'] == name]
        draw_png(keys, name_df, 'name_index', f'results/{name}')

    result_df = df.groupby(['name', 'qps'])[keys].agg(lambda x: sum(x) / len(x)).reset_index()
    draw_png(keys, result_df, 'name', f'results/http_zmq_chunk')
    http_zmq_df = result_df[result_df['name'].isin(['disagg_prefill_zmq', 'disagg_prefill_http'])]
    draw_png(keys, http_zmq_df, 'name', f'results/http_zmq')
