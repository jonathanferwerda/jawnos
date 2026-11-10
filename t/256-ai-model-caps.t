# tests-for: lib/JawnOS/Domain/Device2.pm
# covers:    which names the Plat panel offers for chat and for Vision - the
#           vision families ai_model_caps_by_name must recognise, so a picture
#           model is offered to the Vision role and a text model is not.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

require JawnOS::Domain::Device2;

sub caps { return join '+', subs::ai_model_caps_by_name($_[0]) }

# Vision-only models have no text answer to prove anything with, so they belong
# in the Vision list alone.
is( caps('moondream'), 'vision', 'moondream is a vision model' );
is( caps('llava:13b'), 'vision', 'llava is a vision model' );
is( caps('qwen2.5-vl-7b'), 'vision', 'a qwen2.5 VL model is a vision model' );
is( caps('deepseek-vl2'), 'vision', 'a -vl name is a vision model' );
is( caps('nemotron-nano-vl'), 'vision', 'even when the family comes first' );
is( caps('granite3.2-vision'), 'vision', 'a plain vision suffix still counts' );

# Models that both chat and see.
is( caps('llama4'), 'chat+vision', 'Llama 4 sees images' );
is( caps('llama-4-scout'), 'chat+vision', 'including the tagged name' );
is( caps('mistral-small3.1'), 'chat+vision', 'Mistral Small 3.1 sees images' );
is( caps('mistral-small-3.2'), 'chat+vision', 'and its dotted name' );
is( caps('phi-4-multimodal'), 'chat+vision', 'Phi-4 multimodal sees images' );
is( caps('gpt-4o'), 'chat+vision', 'gpt-4o still does' );
is( caps('gemma3'), 'chat+vision', 'gemma3 still does' );

# Text stays text: the Vision list must not promise sight it does not have.
is( caps('deepseek-flash'), 'chat', 'DeepSeek Flash is a text model' );
is( caps('llama-3.3-70b-instruct'), 'chat', 'a text Llama is not offered to Vision' );
is( caps('mistral-small-latest'), 'chat', 'an untagged Mistral Small is not assumed to see' );

done_testing();
