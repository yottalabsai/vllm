#!/bin/bash

# Requirement: 2x GPUs.


# Model: meta-llama/Meta-Llama-3.1-8B-Instruct
# Query: 1024 input tokens, 6 output tokens, QPS 2/4/6/8, 100 requests
# Resource: 2x GPU
# Approaches:
# 2. Chunked prefill: 2 vllm instance with tp=4, equivalent to 1 tp=4 instance with QPS 4
# 3. Disaggregated prefill: 1 prefilling instance and 1 decoding instance
# Prefilling instance: max_output_token=1
# Decoding instance: force the input tokens be the same across requests to bypass prefilling

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

# a function that waits vLLM disagg to start
wait_for_zmq_server() {
  local pid=$1
  timeout 1200 bash -c "
    until grep -q 'Running requests' <(tail -f /proc/$pid/fd/1); do
      sleep 1
    done" && return 0 || return 1
}


launch_chunked_prefill() {
  model="meta-llama/Meta-Llama-3.1-8B-Instruct"
  gpu_memory_utilization=0.6
  max_model_len=10000
  # disagg prefill
  CUDA_VISIBLE_DEVICES=0 CUDA_LAUNCH_BLOCKING=1 python3 \
    -m vllm.entrypoints.openai.api_server \
    --model $model \
    --port 8100 \
    --max-model-len $max_model_len \
    --enable-chunked-prefill \
    --gpu-memory-utilization $gpu_memory_utilization &
  CUDA_VISIBLE_DEVICES=1 CUDA_LAUNCH_BLOCKING=1 python3 \
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

launch_disagg_prefill_http() {
  model="meta-llama/Meta-Llama-3.1-8B-Instruct" 
  # disagg prefill
  gpu_memory_utilization=0.6
  max_model_len=10000
  CUDA_VISIBLE_DEVICES=0 CUDA_LAUNCH_BLOCKING=1 python3 \
    -m vllm.entrypoints.openai.api_server \
    --model $model \
    --port 8100 \
    --max-model-len $max_model_len \
    --gpu-memory-utilization $gpu_memory_utilization \
    --kv-transfer-config \
    '{"kv_connector":"PyNcclConnector","kv_role":"kv_producer","kv_rank":0,"kv_parallel_size":2,"kv_buffer_size":5e9}' &

  # VLLM_LOGGING_LEVEL=DEBUG CUDA_LAUNCH_BLOCKING=1 
  CUDA_VISIBLE_DEVICES=1 CUDA_LAUNCH_BLOCKING=1 python3 \
    -m vllm.entrypoints.openai.api_server \
    --model $model \
    --port 8200 \
    --max-model-len $max_model_len \
    --gpu-memory-utilization $gpu_memory_utilization \
    --kv-transfer-config \
    '{"kv_connector":"PyNcclConnector","kv_role":"kv_consumer","kv_rank":1,"kv_parallel_size":2,"kv_buffer_size":5e9}' &

  wait_for_server 8100
  wait_for_server 8200
  python3 ../disagg_prefill_proxy_server.py &
  sleep 1
}



launch_disagg_prefill_zmq() {
  model="meta-llama/Meta-Llama-3.1-8B-Instruct" 
  gpu_memory_utilization=0.6
  max_model_len=10000
  zmq_server_addr_prefill=testipc0
  zmq_server_addr_decode=testipc1
  # disagg prefill
  # VLLM_LOGGING_LEVEL=DEBUG CUDA_LAUNCH_BLOCKING=1 
  CUDA_VISIBLE_DEVICES=0 CUDA_LAUNCH_BLOCKING=1 vllm disagg $model \
    --zmq-server-addr $zmq_server_addr_prefill \
    --max-model-len $max_model_len \
    --gpu-memory-utilization $gpu_memory_utilization \
    --kv-transfer-config \
    '{"kv_connector":"PyNcclConnector","kv_role":"kv_producer","kv_rank":0,"kv_parallel_size":2,"kv_buffer_size":5e9}' > vllm_disagg_prefill.log 2>&1 &
  prefill_pid=$!

  # VLLM_LOGGING_LEVEL=DEBUG CUDA_LAUNCH_BLOCKING=1 
  CUDA_VISIBLE_DEVICES=1 CUDA_LAUNCH_BLOCKING=1 vllm disagg $model \
    --zmq-server-addr $zmq_server_addr_decode \
    --max-model-len $max_model_len \
    --gpu-memory-utilization $gpu_memory_utilization \
    --kv-transfer-config \
    '{"kv_connector":"PyNcclConnector","kv_role":"kv_consumer","kv_rank":1,"kv_parallel_size":2,"kv_buffer_size":5e9}' > vllm_disagg_decode.log 2>&1 &
  decode_pid=$!
  
  wait_for_zmq_server "$prefill_pid"
  wait_for_zmq_server "$decode_pid"

  vllm connect \
  --port 8000 \
  --prefill-addr $zmq_server_addr_prefill \
  --decode-addr $zmq_server_addr_decode &

  wait_for_server 8000

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

  rm -rf results
  mkdir results
  mkdir results/http_zmq_chunk
  mkdir results/http_zmq

  default_output_len=6

  export VLLM_HOST_IP=$(hostname -I | awk '{print $1}')
  
  echo "launching chunked prefill"
  launch_chunked_prefill
  for qps in 12 24 48 96; do
    for index in 1 2 3; do
      benchmark $qps $default_output_len chunked_prefill $index
    done
  done
  echo "kill gpu processes start"
  kill_gpu_processes
  echo "kill gpu processes end"
  
  echo "launching disagg prefill http"
  launch_disagg_prefill_http
  for qps in 12 24 48 96; do
    for index in 1 2 3; do
      benchmark $qps $default_output_len disagg_prefill_http $index
    done
  done
  echo "kill gpu processes start"
  kill_gpu_processes
  echo "kill gpu processes end"
  
  echo "launching disagg prefill zmq"
  launch_disagg_prefill_zmq
  for qps in 12 24 48 96; do
    for index in 1 2 3; do
      benchmark $qps $default_output_len disagg_prefill_zmq $index
    done
  done
  echo "kill gpu processes start"
  kill_gpu_processes
  echo "kill gpu processes end"
  

  python3 visualize_benchmark_results_zmq_http_chunked.py

}


main "$@"