#!/bin/bash -e

set -o pipefail

# Make predictions using texts with differently hight inserted WER
# Problematic! Can't run all at once. Need to rename each file to test.txt and put in $DATA_DIR
# and afterwards rename the output and put in a different dir

language=$1
datadir=$2
outdir=$3

export DATA_DIR=$datadir
export SCRIPT_DIR=transformers/examples/token-classification
export MAX_LENGTH=60
export MAX_SEQ_LENGTH=180
export BERT_MODEL=bert-base-multilingual-cased
export OUTPUT_DIR=$outdir
export BATCH_SIZE=16
export NUM_EPOCHS=3
export SAVE_STEPS=3000
export SEED=42

error_calc_dir=utils
# You need to use the directory with your WER inserted files
origwertestdir=./data/wer_testfiles
wertest=$DATA_DIR/wer_test
wertestout=$OUTPUT_DIR/wer_test
tmp=$wertest/tmp
mkdir -p $tmp $wertestout

conda activate tf20env

echo "Get the data on the right format"
# 1. Remove weird symbols and remove space between a word and the following punctuation,
# 2. Put one word (+ a possible punct) per line,
# 3. Add a space between the punct token and the word,
# 4-8. Change the punct symbols from the punctuator 2 look and map puncts to periods, commas and question marks
# 9. Remove stuff stuck to the punct symbol, usually an apostrophe
# 10. Keep only the first two columns (there can be more than one punctuation after a word)
# 11. Remove lines containing only a label or empty
# 12. Add O to empty slots in the 2nd column
for p in 5 10 15 20; do
    (
        sed -re 's/[^A-Za-z0-9 .,:;\?\!$#@%&°\x27\/<>\-]/ /g' -e 's/ +/ /g' -e 's: ([\.,\?\!\:\;\-][A-Z]{4,}):\1:g' \
        < $origwertestdir/wer${p}perc.${language}.txt | tr ' ' '\n' \
        | sed -re 's:([\.,\?\!\:\;\-][A-Z]{4,}): \1:g' \
        -e 's:\-DASH|\:COLON:COMMA:g' \
        -e 's:\;SEMICOLON|\!EXCLAMATIONMARK:PERIOD:g' \
        -e 's:,COMMA:COMMA:g' -e 's:\?QUESTIONMARK:QUESTIONMARK:g' \
        -e 's:\.PERIOD:PERIOD:g' \
        -e 's:(PERIOD|COMMA|QUESTIONMARK)[^ ]+:\1:g' \
        | cut -d' ' -f1,2 \
        | egrep -v '^ |^$' \
        | awk -F' ' '{if ($2 == "") print $1,"O"; else print $0}' \
        > $tmp/wer${p}perc.${language}.txt.tmp
    ) &
done
wait

# Split the data.
for p in 5 10 15 20; do
    (
        awk -v m=$MAX_LENGTH ' {print;} NR % m == 0 { print ""; }' $tmp/wer${p}perc.${language}.txt.tmp > $wertest/wer${p}perc.${language}.txt
    ) &
done

# NOTE! The following needs to be run one at a time
p=5
rm ${DATA_DIR}/cached_test_bert-base-multilingual-cased_256.tf_record
cp $wertest/wer${p}perc.${language}.txt ${DATA_DIR}/test.txt
max_eval_length=256
sbatch \
--job-name=test_pred_${language}_${p}wer \
--output=${DATA_DIR}/tf_${language}_transformer_${d}_pred_${p}wer.log \
--gres=gpu:1 --mem=4G \
--time=0-08:00 \
--wrap="srun \
python3 BERTbased/run_punctuation.py \
--data_dir ${DATA_DIR}/ \
--labels ${DATA_DIR}/labels.txt \
--model_name_or_path $BERT_MODEL \
--output_dir $OUTPUT_DIR \
--max_seq_length $max_eval_length \
--per_device_train_batch_size $BATCH_SIZE \
--save_steps $SAVE_STEPS \
--seed $SEED \
--do_predict"

mv $OUTPUT_DIR/test_results.txt $wertestout/test_results_${p}wer.txt
mv $OUTPUT_DIR/test_predictions.txt $wertestout/test_predictions_${p}wer.txt

# For comparison with Punctuator 2 output
sed -re 's: O$::' -e 's:COMMA:,COMMA:' \
-e 's:QUESTIONMARK:\?QUESTIONMARK:' \
-e 's:PERIOD:.PERIOD:' \
< $wertestout/test_predictions_${p}wer.txt \
| tr '\n' ' ' | sed -r 's: +: :g' \
> $wertestout/test_predictions_punct2_style_${p}wer.txt

sed -r 's/[^A-Za-z0-9 .,:;\?\!$#@%&°\x27\/<>\-]/ /g' -e 's/ +/ /g' \
< $origwertestdir/wer${p}perc.${language}.txt > $tmp/${p}wer.tmp

echo 'Calculate F1-scores'
python $error_calc_dir/error_calculator.py \
$tmp/${p}wer.tmp $wertestout/test_predictions_punct2_style_${p}wer.txt \
> $wertestout/test_punct2error_${p}wer.txt
