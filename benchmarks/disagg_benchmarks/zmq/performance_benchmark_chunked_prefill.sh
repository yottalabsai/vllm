#!/bin/bash

# Requirement: 2x GPUs.


# Model: meta-llama/Meta-Llama-3.1-8B-Instruct
# Query: 1024 input tokens, 6 output tokens, QPS 1/12/24/48/96  , 96 requests
# Resource: 2x GPU
# Approaches:
# Each qps repeat for 3 times and take average
# Chunked prefill: 2 vllm instance with tp=4, equivalent to 1 tp=4 instance with QPS 4
set -ex

kill_gpu_processes() {
  # kill all processes on GPU.
  pgrep pt_main_thread | xargs -r kill -9
  pgrep python3 | xargs -r kill -9
  for port in 8000 8100 8200; do lsof -t -i:$port | xargs -r kill -9; done
  sleep 1
}

wait_for_server() {
  # wait for vllm server to start
  # return 1 if vllm server crashes
  local port=$1
  timeout 1200 bash -c "
    until curl -s localhost:${port}/v1/completions > /dev/null; do
      sleep 1
    done" && return 0 || return 1
}

launch_chunked_prefill() {
  model="meta-llama/Meta-Llama-3.1-8B-Instruct"
  gpu_memory_utilization=0.6
  max_model_len=10000
  # disagg prefill
  VLLM_LOGGING_LEVEL=DEBUG CUDA_VISIBLE_DEVICES=0 python3 \
    -m vllm.entrypoints.openai.api_server \
    --model $model \
    --port 8100 \
    --max-model-len $max_model_len \
    --enable-chunked-prefill \
    --gpu-memory-utilization $gpu_memory_utilization &
  VLLM_LOGGING_LEVEL=DEBUG CUDA_VISIBLE_DEVICES=1 python3 \
    -m vllm.entrypoints.openai.api_server \
    --model $model \
    --port 8200 \
    --max-model-len $max_model_len \
    --enable-chunked-prefill \
    --gpu-memory-utilization $gpu_memory_utilization &
  wait_for_server 8100
  wait_for_server 8200
  python3 ../round_robin_proxy.py &
  sleep 1
}


benchmark() {
  results_folder="./results"
  model="meta-llama/Meta-Llama-3.1-8B-Instruct"
  dataset_name="sonnet"
  dataset_path="../../sonnet_4x.txt"
  num_prompts=96
  qps=$1
  prefix_len=50
  input_len=1024
  output_len=$2
  tag=$3
  index=$4

  python3 ../../benchmark_serving.py \
          --backend vllm \
          --model $model \
          --dataset-name $dataset_name \
          --dataset-path $dataset_path \
          --sonnet-input-len $input_len \
          --sonnet-output-len "$output_len" \
          --sonnet-prefix-len $prefix_len \
          --num-prompts $num_prompts \
          --port 8000 \
          --save-result \
          --result-dir $results_folder \
          --result-filename "$tag"_qps_"$qps"_"$index".json \
          --request-rate "$qps"

  sleep 2
}


main() {

  (which wget && which curl) || (apt-get update && apt-get install -y wget curl)
  (which jq) || (apt-get -y install jq)
  (which socat) || (apt-get -y install socat)
  (which lsof) || (apt-get -y install lsof)
  pip install quart httpx matplotlib aiohttp datasets
  cd "$(dirname "$0")"
  cd ../..
  # create sonnet-4x.txt so that we can sample 2048 tokens for input
  echo "" > sonnet_4x.txt
  for _ in {1..4}
  do
    cat sonnet.txt >> sonnet_4x.txt
  done

  cd disagg_benchmarks/zmq
  rm -rf results/chunked_prefill
  mkdir -p results/chunked_prefill
  
  default_output_len=6

  export VLLM_HOST_IP=$(hostname -I | awk '{print $1}')
  
  launch_chunked_prefill
  for qps in 1 12 24 48 96; do
    for index in 1 2 3; do
      benchmark $qps $default_output_len chunked_prefill $index
    done
  done
  kill_gpu_processes
  sleep 3

  echo "DONE"
}


main "$@"
