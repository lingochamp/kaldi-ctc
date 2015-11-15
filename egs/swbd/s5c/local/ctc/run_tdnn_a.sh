#!/bin/bash

# see results at end of file

set -e

# configs for ctc
stage=0
train_stage=-10
# running first with speed_perturb=false for speed.
speed_perturb=false
dir=exp/ctc/tdnn_a  # Note: _sp will get added to this if $speed_perturb == true.
common_egs_dir=  # be careful with this: it's dependent on the CTC transition model


# TDNN options
splice_indexes="-2,-1,0,1,2 -1,2 -3,3 -7,2 0"

# training options
num_epochs=4
initial_effective_lrate=0.0017
final_effective_lrate=0.00017
num_jobs_initial=3
num_jobs_final=16
minibatch_size=256
frames_per_eg=75
remove_egs=false

# End configuration section.
echo "$0 $@"  # Print the command line for logging

. cmd.sh
. ./path.sh
. ./utils/parse_options.sh

if ! cuda-compiled; then
  cat <<EOF && exit 1
This script is intended to be used with GPUs but you have not compiled Kaldi with CUDA
If you want to use GPUs (and have them), go to src/, and configure and make on a machine
where "nvcc" is installed.
EOF
fi

# The iVector-extraction and feature-dumping parts are the same as the standard
# nnet3 setup, and you can skip them by setting "--stage 8" if you have already
# run those things.

suffix=
if [ "$speed_perturb" == "true" ]; then
  suffix=_sp
fi

dir=${dir}$suffix
train_set=train_nodup$suffix
ali_dir=exp/tri4_ali_nodup$suffix
treedir=exp/ctc/tri5b_tree$suffix

# if we are using the speed-perturbed data we need to generate
# alignments for it.
local/nnet3/run_ivector_common.sh --stage $stage \
  --speed-perturb $speed_perturb \
  --generate-alignments $speed_perturb || exit 1;

if [ $stage -le 9 ]; then
  # Create a version of the lang/ directory that has one state per phone in the
  # topo file.
  lang=data/lang_ctc
  rm -rf $lang
  cp -r data/lang $lang
  silphonelist=$(cat $lang/phones/silence.csl) || exit 1;
  nonsilphonelist=$(cat $lang/phones/nonsilence.csl) || exit 1;
  utils/gen_topo.pl 1 1 $nonsilphonelist $silphonelist >$lang/topo
fi

if [ $stage -le 10 ]; then
  # Starting from the alignments in tri4_ali_nodup*, we train a rudimentary
  # LDA+MLLT system with a 1-state HMM topology and with only left phonetic
  # context (one phone's worth of left context, for now).  We set "--num-iters
  # 1" because we only need the tree from this system.
  steps/train_sat.sh --cmd "$train_cmd" --num-iters 1 \
    --tree-stats-opts "--collapse-pdf-classes=true" \
    --cluster-phones-opts "--pdf-class-list=0" \
    --context-opts "--context-width=2 --central-position=1" \
     5000 20000 data/$train_set data/lang_ctc $ali_dir $treedir
fi

if [ $stage -le 11 ]; then
  # Get the alignments as lattices (gives the CTC training more freedom).
  # use the same num-jobs as the alignments
  nj=$(cat exp/tri4_ali_nodup$suffix/num_jobs) || exit 1;
  steps/align_fmllr_lats.sh --nj $nj --cmd "$train_cmd" data/$train_set \
    data/lang exp/tri4 exp/tri4_lats_nodup$suffix
  rm exp/tri4_lats_nodup$suffix/fsts.*.gz # save space
fi

if [ $stage -le 12 ]; then
  if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d $dir/egs/storage ]; then
    utils/create_split_dir.pl \
     /export/b0{1,2,3,4}/$USER/kaldi-data/egs/swbd-$(date +'%m_%d_%H_%M')/s5/$dir/egs/storage $dir/egs/storage
  fi

 touch $dir/egs/.nodelete # keep egs around when that run dies.

  # adding --target-num-history-states 500 to match the egs of run_lstm_a.sh.  The
  # script must have had a different default at that time.
  steps/nnet3/ctc/train_tdnn.sh --stage $train_stage \
    --left-deriv-truncate 5  --right-deriv-truncate 5  --right-tolerance 5 \
    --minibatch-size $minibatch_size \
    --egs-opts "--frames-overlap-per-eg 10" \
    --target-num-history-states 2000 \
    --frames-per-eg $frames_per_eg \
    --num-epochs $num_epochs --num-jobs-initial $num_jobs_initial --num-jobs-final $num_jobs_final \
    --splice-indexes "$splice_indexes" \
    --feat-type raw \
    --online-ivector-dir exp/nnet3/ivectors_${train_set} \
    --cmvn-opts "--norm-means=false --norm-vars=false" \
    --initial-effective-lrate $initial_effective_lrate --final-effective-lrate $final_effective_lrate \
    --relu-dim 1024 \
    --cmd "$decode_cmd" \
    --remove-egs $remove_egs \
    data/${train_set}_hires data/lang_ctc $treedir exp/tri4_lats_nodup$suffix $dir  || exit 1;
fi

if [ $stage -le 13 ]; then
  steps/nnet3/ctc/mkgraph.sh --phone-lm-weight 0.0 \
      data/lang_sw1_tg $dir $dir/graph_sw1_tg
fi

decode_suff=sw1_tg
graph_dir=$dir/graph_sw1_tg
if [ $stage -le 14 ]; then
  for decode_set in train_dev eval2000; do
      (
      num_jobs=`cat data/$mic/${decode_set}_hires/utt2spk|cut -d' ' -f2|sort -u|wc -l`
      steps/nnet3/ctc/decode.sh --nj 50 --cmd "$decode_cmd" \
          --online-ivector-dir exp/nnet3/ivectors_${decode_set} \
         $graph_dir data/${decode_set}_hires $dir/decode_${decode_set}_${decode_suff} || exit 1;
      if $has_fisher; then
          steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" \
            data/lang_sw1_{tg,fsh_fg} data/${decode_set}_hires \
            $dir/decode_${decode_set}_sw1_{tg,fsh_fg} || exit 1;
      fi
      ) &
  done
fi

# trying the same decoding but with different frame shifts; I want to see if
# there is any combination effect.
if [ $stage -le 15 ]; then
  for decode_set in eval2000; do # train_dev eval2000
    for shift in 1 -1; do
     (
      num_jobs=`cat data/$mic/${decode_set}_hires/utt2spk|cut -d' ' -f2|sort -u|wc -l`
      steps/nnet3/ctc/decode.sh --nj 50 --cmd "$decode_cmd" --shift $shift \
          --online-ivector-dir exp/nnet3/ivectors_${decode_set} \
         $graph_dir data/${decode_set}_hires $dir/decode_${decode_set}_${decode_suff}_shift$shift || exit 1;
      if $has_fisher; then
          steps/lmrescore_const_arpa.sh --cmd "$decode_cmd" \
            data/lang_sw1_{tg,fsh_fg} data/${decode_set}_hires \
            $dir/decode_${decode_set}_sw1_{tg,fsh_fg}_shift$shift || exit 1;
      fi
      ) &
    done
  done
  wait
fi

if [ $stage -le 16 ]; then
  for decode_set in train_dev eval2000; do
    for lm_suffix in sw1_tg sw1_fsh_fg; do
   (
    # this combination script only combines things to at a time, so use it twice.
    steps/decode_combine.sh --cmd "$decode_cmd" \
        data/${decode_set} data/lang_${lm_suffix}  exp/ctc/tdnn_a_sp/decode_${decode_set}_${lm_suffix} exp/ctc/tdnn_a_sp/decode_${decode_set}_${lm_suffix}_shift1 exp/ctc/tdnn_a_sp/decode_${decode_set}_${lm_suffix}_shift0_1
    steps/decode_combine.sh --cmd "$decode_cmd" \
      --weight1 0.666 data/${decode_set} data/lang_${lm_suffix}  exp/ctc/tdnn_a_sp/decode_${decode_set}_${lm_suffix}_shift0_1 exp/ctc/tdnn_a_sp/decode_${decode_set}_${lm_suffix}_shift-1 exp/ctc/tdnn_a_sp/decode_${decode_set}_${lm_suffix}_shift0_1_-1
   ) &
    done
  done
  wait
fi

# the frame-shift combination gives us 0.6% abs on eval2000, swbd subset.
#b01:s5c: grep Sum exp/ctc/tdnn_a_sp/decode_eval2000_sw1_fsh_fg/score*/*ys | utils/best_wer.sh
#%WER 13.1 | 1831 21395 | 88.4 8.0 3.6 1.5 13.1 50.6 | exp/ctc/tdnn_a_sp/decode_eval2000_sw1_fsh_fg/score_11_0.0/eval2000_hires.ctm.swbd.filt.sys
#b01:s5c: grep Sum exp/ctc/tdnn_a_sp/decode_eval2000_sw1_fsh_fg_shift0_1_-1/score*/*ys | utils/best_wer.sh
#%WER 12.5 | 1831 21395 | 88.9 7.6 3.5 1.4 12.5 49.5 | exp/ctc/tdnn_a_sp/decode_eval2000_sw1_fsh_fg_shift0_1_-1/score_11_0.0/eval2000.ctm.swbd.filt.sys
#b01:s5c:


#b01:s5c: cat exp/ctc/tdnn_a_sp/decode_train_dev_sw1_tg/wer_* | utils/best_wer.sh
#%WER 19.48 [ 9587 / 49204, 1214 ins, 2364 del, 6009 sub ]
#b01:s5c: cat exp/ctc/tdnn_a_sp/decode_train_dev_sw1_tg_shift1/wer_* | utils/best_wer.sh
#%WER 19.38 [ 9534 / 49204, 1110 ins, 2510 del, 5914 sub ]
#b01:s5c: cat exp/ctc/tdnn_a_sp/decode_train_dev_sw1_tg_shift-1/wer_* | utils/best_wer.sh
#%WER 19.64 [ 9665 / 49204, 1111 ins, 2688 del, 5866 sub ]
#b01:s5c: cat exp/ctc/tdnn_a_sp/decode_train_dev_sw1_tg_shift0_1/wer_* | utils/best_wer.sh
#%WER 18.67 [ 9187 / 49204, 1059 ins, 2519 del, 5609 sub ]
#cat exp/ctc/tdnn_a_sp/decode_train_dev_sw1_tg_shift0_1_-1/wer_* | utils/best_wer.sh
#%WER 18.37 [ 9041 / 49204, 1026 ins, 2542 del, 5473 sub ]


wait;
exit 0;


#b01:s5c: grep Overall exp/ctc/tdnn_a_sp/log/compute_prob_*.final.log
#exp/ctc/tdnn_a_sp/log/compute_prob_train.final.log:LOG (nnet3-ctc-compute-prob:PrintTotalStats():nnet-cctc-diagnostics.cc:134) Overall log-probability for 'output' is -0.0214241 per frame, over 20000 frames = -0.294677 + 0.273253
#exp/ctc/tdnn_a_sp/log/compute_prob_valid.final.log:LOG (nnet3-ctc-compute-prob:PrintTotalStats():nnet-cctc-diagnostics.cc:134) Overall log-probability for 'output' is -0.0325563 per frame, over 20000 frames = -0.319421 + 0.286865
#b01:s5c: grep Overall exp/ctc/tdnn_a/log/compute_prob_*.final.log
#exp/ctc/tdnn_a/log/compute_prob_train.final.log:LOG (nnet3-ctc-compute-prob:PrintTotalStats():nnet-cctc-diagnostics.cc:134) Overall log-probability for 'output' is -0.0178068 per frame, over 20000 frames = -0.29416 + 0.276353
#exp/ctc/tdnn_a/log/compute_prob_valid.final.log:LOG (nnet3-ctc-compute-prob:PrintTotalStats():nnet-cctc-diagnostics.cc:134) Overall log-probability for 'output' is -0.0468761 per frame, over 20000 frames = -0.335203 + 0.288326

# results without speed perturbation:
# for x in exp/ctc/tdnn_a/decode_eval2000_sw1_{tg,fsh_fg}; do grep Sum $x/score_*/*.ctm.swbd.filt.sys | utils/best_wer.sh; done
# %WER 16.3 | 1831 21395 | 85.7 10.0 4.4 2.0 16.3 55.2 | exp/ctc/tdnn_a/decode_eval2000_sw1_tg/score_11_0.0/eval2000_hires.ctm.swbd.filt.sys
# %WER 14.5 | 1831 21395 | 87.0 8.7 4.3 1.6 14.5 52.3 | exp/ctc/tdnn_a/decode_eval2000_sw1_fsh_fg/score_12_0.0/eval2000_hires.ctm.swbd.filt.sys

# results with speed perturbation:
# for x in exp/ctc/tdnn_a_sp/decode_eval2000_sw1_{tg,fsh_fg}; do grep Sum $x/score_*/*.ctm.swbd.filt.sys | utils/best_wer.sh; done
# %WER 14.9 | 1831 21395 | 86.9 9.2 3.9 1.8 14.9 53.5 | exp/ctc/tdnn_a_sp/decode_eval2000_sw1_tg/score_11_0.0/eval2000_hires.ctm.swbd.filt.sys
# %WER 13.1 | 1831 21395 | 88.4 8.0 3.6 1.5 13.1 50.6 | exp/ctc/tdnn_a_sp/decode_eval2000_sw1_fsh_fg/score_11_0.0/eval2000_hires.ctm.swbd.filt.sys