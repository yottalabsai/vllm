import json
import os
import random

import matplotlib.pyplot as plt
from numpy import single
import pandas as pd
from sympy import N


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
        # for qps in [1, 12, 24, 48, 96]:
        for qps in [1, 12, 24]:
            for index in range(1, 4):
                with open(f"results/{name}/{name}_qps_{qps}_{index}.json") as f:
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
    # i= 0
    # for key in keys:
    #     for i, row in df.iterrows():
    #         df.at[i, key] = i
    #         i += 1



    # for name in names:
    #     name_df = df[df['name'] == name]
    #     draw_png(keys, name_df, 'name_index', f'results/{name}')
    #     print(name_df)
    #     print('\n\n')


    result_df = df.groupby(['name', 'qps'])[keys].agg(lambda x: sum(x) / len(x)).reset_index()
    # print(result_df)
    # draw_png(keys, result_df, 'name', f'results/http_zmq_chunk')
    http_zmq_df = result_df[result_df['name'].isin(['disagg_prefill_zmq', 'disagg_prefill_http'])]
    print(http_zmq_df)
    draw_png(keys, http_zmq_df, 'name', f'results/http_zmq')

    
    


    # dis_zmq_df = df[df['name'] == 'disagg_prefill_zmq']
    # chu_df = df[df['name'] == 'chunked_prefill']

    # draw_png(keys, df, [dis_http_df, dis_zmq_df, chu_df], 'results/http_zmq_chunk')
    # draw_png(keys, df, [dis_http_df, dis_zmq_df, chu_df], 'results/http_zmq')
#               name  index             name_index  qps
#  disagg_prefill_http      3  disagg_prefill_http_3    1
#  disagg_prefill_http      3  disagg_prefill_http_3   12
# disagg_prefill_http      3  disagg_prefill_http_3   24
