num_args=$#
max_runs=$1
sleep=$2
cmd=$3
shift 3
args=("$@")
runs=0
[[ $num_args -le 2 ]] && echo "Usage retry.sh <sleep> <retry_times> <command>" && exit 0;
until [[ $runs -ge $max_runs ]]
do
  if $cmd "${args[@]}"; then
    break;
  else
    echo "Failed"
    ((runs++))
    echo "retry $runs ::"
    sleep "$sleep";
  fi
done