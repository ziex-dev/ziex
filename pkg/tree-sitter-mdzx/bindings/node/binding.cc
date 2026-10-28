#include <napi.h>

typedef struct TSLanguage TSLanguage;

extern "C" TSLanguage *tree_sitter_mdzx();
extern "C" TSLanguage *tree_sitter_mdzx_inline();

// "tree-sitter", "language" hashed with BLAKE2
const napi_type_tag LANGUAGE_TYPE_TAG = {
    0x8AF2E5212AD58ABF, 0xD5006CAD83ABBA16
};

Napi::Object Init(Napi::Env env, Napi::Object exports) {
    auto language = Napi::External<TSLanguage>::New(env, tree_sitter_mdzx());
    language.TypeTag(&LANGUAGE_TYPE_TAG);
    exports["language"] = language;

    auto inline_language = Napi::External<TSLanguage>::New(env, tree_sitter_mdzx_inline());
    inline_language.TypeTag(&LANGUAGE_TYPE_TAG);
    auto inline_exports = Napi::Object::New(env);
    inline_exports["language"] = inline_language;
    exports["inline"] = inline_exports;

    return exports;
}

NODE_API_MODULE(tree_sitter_mdzx_binding, Init)
