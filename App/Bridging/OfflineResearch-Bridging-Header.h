//
//  Bridging header for the llama.cpp C API.
//
//  The static library (vendor/llama/lib/<sdk>/libllamaios.a) and headers
//  (vendor/llama/include) are produced by Scripts/build_llama.sh.
//  Building without them is supported: `make project-nollama` sets
//  NO_LLAMA_ENGINE=1, which compiles the app in retrieval-only mode.
//

#ifndef OFFLINE_RESEARCH_BRIDGING_HEADER_H
#define OFFLINE_RESEARCH_BRIDGING_HEADER_H

#if !defined(NO_LLAMA_ENGINE)
#include "llama.h"
#endif

#endif /* OFFLINE_RESEARCH_BRIDGING_HEADER_H */
