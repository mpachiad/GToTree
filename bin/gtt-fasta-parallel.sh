#!/usr/bin/env bash

# setting colors to use
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

tmp_dir=$2
hmm_file=$3
num_cpus=$4
hmm_target_genes_total=$5
output_dir=$6
best_hit_mode=$7


### kill backstop
# if there is a problem, all child processes launched (by this script) will exit immediately,
# upon returning to main script, will check and terminate parent process
if [ -s ${tmp_dir}/kill_fasta_parallel.prodigal ]; then
    exit
fi

## checking if gzipped, gunzipping if so, and setting assembly name and file location variable either way
if $(file $1 | grep -q "gzip"); then
    was_gzipped=TRUE # setting variable to be able to check and remove gunzipped file afterwards
    file_location=${1%.*}
    gunzip -c $1 > $file_location
    assembly="$(basename ${file_location%.*})"
else
    file_location=$1
    assembly="$(basename ${1%.*})"
    was_gzipped=FALSE
fi

printf "   --------------------------------------------------------------------------   \n\n"
printf "     Genome: ${GREEN}$assembly${NC}\n"

# adding assembly to ongoing genomes list
echo $assembly >> ${tmp_dir}/fasta_genomes_list.tmp

num=$((num+1)) # to track progress


prodigal -c -q -i $file_location -a ${tmp_dir}/${assembly}_genes1.tmp > /dev/null 2> ${file_location}_prodigal.stderr

if [ -s ${file_location}_prodigal.stderr ]; then
    printf "$assembly" >> ${tmp_dir}/kill_fasta_parallel.prodigal
    rm -rf ${file_location}_prodigal.stderr
    exit
else
    rm -rf ${file_location}_prodigal.stderr
fi

tr -d '*' < ${tmp_dir}/${assembly}_genes1.tmp > ${tmp_dir}/${assembly}_genes2.tmp


## removing gunzipped genome file if it was gunzipped
if [ $was_gzipped == "TRUE" ]; then
    rm -rf $file_location
fi

## renaming seqs to have assembly name
gtt-rename-fasta-headers -i ${tmp_dir}/${assembly}_genes2.tmp -w $assembly -o ${tmp_dir}/${assembly}_genes.tmp
  
### running hmm search ###
hmmsearch --cut_ga --cpu $num_cpus --tblout ${tmp_dir}/${assembly}_curr_hmm_hits.tmp $hmm_file ${tmp_dir}/${assembly}_genes.tmp > /dev/null

### calculating % completion and redundancy ###
for SCG in $(cat ${tmp_dir}/uniq_hmm_names.tmp)
do
    grep -w -c "$SCG" ${tmp_dir}/${assembly}_curr_hmm_hits.tmp
done > ${tmp_dir}/${assembly}_uniq_counts.tmp

## making list here of only those present in exactly 1 copy
paste ${tmp_dir}/uniq_hmm_names.tmp ${tmp_dir}/${assembly}_uniq_counts.tmp > ${tmp_dir}/${assembly}_conservative_filtering_counts_tab.tmp
awk -F "\t" ' $2 == 1 ' ${tmp_dir}/${assembly}_conservative_filtering_counts_tab.tmp | cut -f 1 > ${tmp_dir}/${assembly}_conservative_target_unique_hmm_names.tmp
uniq_SCG_hits=$(wc -l ${tmp_dir}/${assembly}_conservative_target_unique_hmm_names.tmp | sed 's/^ *//' | cut -f 1 -d " ")

## adding SCG-hit counts to table
paste <(printf $assembly) <(printf %s "$(cat ${tmp_dir}/${assembly}_uniq_counts.tmp | tr "\n" "\t")") >> ${output_dir}/All_genomes_SCG_hit_counts.tsv

num_SCG_hits=$(awk ' $1 > 0 ' ${tmp_dir}/${assembly}_uniq_counts.tmp | wc -l | tr -s " " | cut -f2 -d " ")

num_SCG_redund=$(awk '{ if ($1 == 0) { print $1 } else { print $1 - 1 } }' ${tmp_dir}/${assembly}_uniq_counts.tmp | awk '{ sum += $1 } END { print sum }')

perc_comp=$(echo "$num_SCG_hits / $hmm_target_genes_total * 100" | bc -l)
perc_comp_rnd=$(printf "%.2f\n" $perc_comp)
perc_redund=$(echo "$num_SCG_redund / $hmm_target_genes_total * 100" | bc -l)
perc_redund_rnd=$(printf "%.2f\n" $perc_redund)

### want to put an explicit notice out if estimated redundancy is greater than 10%
# needs to be an integer for bash comparison, so multiplying by 100 first

mult_perc_redund_rnd=$(echo "$perc_redund_rnd * 100" | bc | cut -f 1 -d ".")

printf "             Found $num_SCG_hits of the targeted $hmm_target_genes_total genes.\n"

if [ ${mult_perc_redund_rnd} -ge 1000 ]; then
    printf "             Est. %% comp: ${perc_comp_rnd}; Est. %% redund: ${RED}${perc_redund_rnd}${NC}\n\n"


    printf "  ${RED}********************************** ${NC}NOTICE ${RED}**********************************${NC}  \n"
    printf "   Estimated redundancy of this genome based on the specified HMMs is ${RED}${perc_redund_rnd}%%${NC}.\n"
    printf "   While there are no \"golden\" cutoff values for these things, typically\n"
    printf "   going over 10%% is getting into the questionable range. You may want to\n"
    printf "   consider taking a closer look and/or removing it from the input genomes.\n\n"

    printf "   Reported in \"${output_dir}/Genomes_with_questionable_redund_estimates.tsv\".\n"
    printf "  ${RED}****************************************************************************${NC}  \n\n"

    # writing to table of genomes with questionable redundancy estimates
    printf "$assembly\t$num_SCG_hits\t$uniq_SCG_hits\t$perc_comp_rnd\t$perc_redund_rnd\n" >> ${tmp_dir}/Genomes_with_questionable_redundancy_estimates.tmp

else
    printf "             Est. %% comp: ${perc_comp_rnd}; Est. %% redund: ${perc_redund_rnd}\n\n"
fi

# adding NA for taxid so final table can still have the column and lineage for those that do have them
taxid="NA"

## writing summary info to table ##
printf "$assembly\t$1\t$taxid\t$num_SCG_hits\t$uniq_SCG_hits\t$perc_comp_rnd\t$perc_redund_rnd\n" >> ${output_dir}/Fasta_genomes_summary_info.tsv

### Pulling out hits for this genome ###
# looping through SCGs and pulling out each first hit (hmm results tab is sorted by e-value):
esl-sfetch --index ${tmp_dir}/${assembly}_genes.tmp > /dev/null

# if best-hit mode is off, then only pulling genes that were identified in exactly 1 copy
if [ $best_hit_mode  == "false" ]; then

    for SCG in $(cat ${tmp_dir}/${assembly}_conservative_target_unique_hmm_names.tmp)
    do
        grep -w "$SCG" ${tmp_dir}/${assembly}_curr_hmm_hits.tmp | awk '!x[$3]++' | cut -f1 -d " " | esl-sfetch -f ${tmp_dir}/${assembly}_genes.tmp - | sed "s/>.*$/>$assembly/" | sed 's/^Usage.*$//' | sed 's/^To see.*$//' | sed '/^$/d' >> ${tmp_dir}/${SCG}_hits.faa
    done

# if best-hit mode is on, taking best hit
else

    for SCG in $(cat ${tmp_dir}/uniq_hmm_names.tmp)
    do
        grep -w "$SCG" ${tmp_dir}/${assembly}_curr_hmm_hits.tmp | awk '!x[$3]++' | cut -f1 -d " " | esl-sfetch -f ${tmp_dir}/${assembly}_genes.tmp - | sed "s/>.*$/>$assembly/" | sed 's/^Usage.*$//' | sed 's/^To see.*$//' | sed '/^$/d' >> ${tmp_dir}/${SCG}_hits.faa
    done

fi

rm -rf ${tmp_dir}/${assembly}_*.tmp ${tmp_dir}/${assembly}_genes.tmp.ssi
