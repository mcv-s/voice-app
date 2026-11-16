#include "NotesLLM.h"
#include <llama/llama.h>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <memory>
#include <string>
#include <vector>

struct VoiceNotesModel {
    llama_model *model = nullptr;
    llama_context *context = nullptr;
    const llama_vocab *vocab = nullptr;
    ~VoiceNotesModel() { if (context) llama_free(context); if (model) llama_model_free(model); }
};
static VoiceNotesModel *createImpl(const char *path) {
    static std::once_flag initialized;
    std::call_once(initialized, [] {
        llama_log_set([](ggml_log_level level, const char *text, void *) { if (level == GGML_LOG_LEVEL_ERROR) fputs(text, stderr); }, nullptr);
        llama_backend_init();
    });
    std::unique_ptr<VoiceNotesModel> owner(new VoiceNotesModel());
    auto *notes = owner.get();
    auto mp = llama_model_default_params(); mp.n_gpu_layers = 0;
    notes->model = llama_model_load_from_file(path, mp);
    if (!notes->model) { return nullptr; }
    auto cp = llama_context_default_params(); cp.n_ctx = 2048; cp.n_batch = 256;
    cp.n_threads = 2; cp.n_threads_batch = 2;
    notes->context = llama_init_from_model(notes->model, cp);
    notes->vocab = llama_model_get_vocab(notes->model);
    if (!notes->context || !notes->vocab) { return nullptr; }
    return owner.release();
}
VoiceNotesModel *VoiceNotesCreate(const char *path) {
    try { return createImpl(path); } catch (...) { return nullptr; }
}
void VoiceNotesDestroy(VoiceNotesModel *model) { delete model; }
static char *completeImpl(VoiceNotesModel *notes, const char *prompt, int max_tokens, VoiceNotesCancelled cancelled) {
    if (!notes || !prompt) return nullptr;
    llama_memory_clear(llama_get_memory(notes->context), true);
    int count = -llama_tokenize(notes->vocab, prompt, (int)strlen(prompt), nullptr, 0, true, true);
    if (count <= 0 || count + max_tokens >= 2048) return nullptr;
    std::vector<llama_token> tokens(count);
    if (llama_tokenize(notes->vocab, prompt, (int)strlen(prompt), tokens.data(), count, true, true) != count) return nullptr;
    for (int start = 0; start < count; start += 256) {
        if (cancelled && cancelled()) return nullptr;
        if (llama_decode(notes->context, llama_batch_get_one(tokens.data() + start, std::min(256, count - start))) != 0) return nullptr;
    }
    const char *grammar = R"GRAMMAR(root ::= "{" ws "\"title\"" ws ":" ws title ws "," ws "\"summary\"" ws ":" ws summary ws "}" ws
        title ::= "\"" char{1,90} "\""
        summary ::= "\"" char{1,900} "\""
        char ::= [^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4})
        ws ::= [ \t\n\r]*
    )GRAMMAR";
    auto *sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (sampler) {
        auto *constraints = llama_sampler_init_grammar(notes->vocab, grammar, "root");
        if (!constraints) { llama_sampler_free(sampler); return nullptr; }
        llama_sampler_chain_add(sampler, constraints);
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    }
    if (!sampler) return nullptr;
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> owner(sampler, llama_sampler_free);
    std::string output;
    bool ok = true;
    for (int i = 0; i < max_tokens; ++i) {
        if (cancelled && cancelled()) { ok = false; break; }
        auto token = llama_sampler_sample(sampler, notes->context, -1);
        if (llama_vocab_is_eog(notes->vocab, token)) break;
        std::vector<char> piece(256);
        int size = llama_token_to_piece(notes->vocab, token, piece.data(), (int)piece.size(), 0, true);
        if (size < 0) { piece.resize(-size); size = llama_token_to_piece(notes->vocab, token, piece.data(), (int)piece.size(), 0, true); }
        if (size > 0) output.append(piece.data(), size);
        if (llama_decode(notes->context, llama_batch_get_one(&token, 1)) != 0) { ok = false; break; }
    }
    return ok ? strdup(output.c_str()) : nullptr;
}
char *VoiceNotesComplete(VoiceNotesModel *notes, const char *prompt, int max_tokens, VoiceNotesCancelled cancelled) {
    try { return completeImpl(notes, prompt, max_tokens, cancelled); }
    catch (...) { return nullptr; }
}
void VoiceNotesFreeString(char *text) { free(text); }
