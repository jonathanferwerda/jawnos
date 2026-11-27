/*
 * The sherpa-onnx C ABI this tree binds to.
 *
 * scripts/build_engine.pl compiles this against the include/ directory of the
 * sherpa-onnx v2.0.3 shared asset and compares every key/value line with the
 * expected map embedded in that script. The same numbers are asserted at
 * compile time by the const block at the end of engine/src/sherpa.rs. Keep the
 * two in step: a field added to either place is a gate that has gone stale.
 *
 * Usage:
 *   cc -I <asset>/include engine/tests/sherpa_abi_probe.c -o probe && ./probe
 */
#include <stddef.h>
#include <stdio.h>

#include <sherpa-onnx/c-api/c-api.h>

int main(void) {
  /* one key/value line per ABI fact */
  printf("feature_config.size\t%zu\n", sizeof(SherpaOnnxFeatureConfig));
  printf("feature_config.sample_rate\t%zu\n",
         offsetof(SherpaOnnxFeatureConfig, sample_rate));
  printf("feature_config.feature_dim\t%zu\n",
         offsetof(SherpaOnnxFeatureConfig, feature_dim));

  printf("transducer.size\t%zu\n", sizeof(SherpaOnnxOnlineTransducerModelConfig));
  printf("transducer.encoder\t%zu\n",
         offsetof(SherpaOnnxOnlineTransducerModelConfig, encoder));
  printf("transducer.decoder\t%zu\n",
         offsetof(SherpaOnnxOnlineTransducerModelConfig, decoder));
  printf("transducer.joiner\t%zu\n",
         offsetof(SherpaOnnxOnlineTransducerModelConfig, joiner));

  printf("model_config.size\t%zu\n", sizeof(SherpaOnnxOnlineModelConfig));
  printf("model_config.transducer\t%zu\n",
         offsetof(SherpaOnnxOnlineModelConfig, transducer));
  printf("model_config.tokens\t%zu\n",
         offsetof(SherpaOnnxOnlineModelConfig, tokens));
  printf("model_config.num_threads\t%zu\n",
         offsetof(SherpaOnnxOnlineModelConfig, num_threads));
  printf("model_config.provider\t%zu\n",
         offsetof(SherpaOnnxOnlineModelConfig, provider));

  printf("recognizer_config.size\t%zu\n",
         sizeof(SherpaOnnxOnlineRecognizerConfig));
  printf("recognizer_config.feat_config\t%zu\n",
         offsetof(SherpaOnnxOnlineRecognizerConfig, feat_config));
  printf("recognizer_config.model_config\t%zu\n",
         offsetof(SherpaOnnxOnlineRecognizerConfig, model_config));
  printf("recognizer_config.decoding_method\t%zu\n",
         offsetof(SherpaOnnxOnlineRecognizerConfig, decoding_method));
  printf("recognizer_config.max_active_paths\t%zu\n",
         offsetof(SherpaOnnxOnlineRecognizerConfig, max_active_paths));
  printf("recognizer_config.enable_endpoint\t%zu\n",
         offsetof(SherpaOnnxOnlineRecognizerConfig, enable_endpoint));
  printf("recognizer_config.rule1_min_trailing_silence\t%zu\n",
         offsetof(SherpaOnnxOnlineRecognizerConfig, rule1_min_trailing_silence));
  printf("recognizer_config.rule2_min_trailing_silence\t%zu\n",
         offsetof(SherpaOnnxOnlineRecognizerConfig, rule2_min_trailing_silence));
  printf("recognizer_config.rule3_min_utterance_length\t%zu\n",
         offsetof(SherpaOnnxOnlineRecognizerConfig, rule3_min_utterance_length));
  printf("recognizer_config.hotwords_score\t%zu\n",
         offsetof(SherpaOnnxOnlineRecognizerConfig, hotwords_score));

  return 0;
}
