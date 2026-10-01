/* tslint:disable */
/* eslint-disable */

export class BrotliDecStream {
    free(): void;
    [Symbol.dispose](): void;
    dec(input: Uint8Array, output_size: number): BrotliStreamResult;
    /**
     * See [`Self::dec()`].
     *
     * For drop-in replacement of `brotli-wasm`.
     */
    decompress(input: Uint8Array, output_size: number): BrotliStreamResult;
    constructor();
    total_out(): number;
}

/**
 * From [`brotli_decompressor::state::BrotliDecoderErrorCode`].
 * NOTICE: All numbers are reversed to positive, required by wasm_bindgen.
 */
export enum BrotliDecStreamErrCode {
    BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_NIBBLE = 1,
    BROTLI_DECODER_ERROR_FORMAT_RESERVED = 2,
    BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_META_NIBBLE = 3,
    BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_ALPHABET = 4,
    BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_SAME = 5,
    BROTLI_DECODER_ERROR_FORMAT_CL_SPACE = 6,
    BROTLI_DECODER_ERROR_FORMAT_HUFFMAN_SPACE = 7,
    BROTLI_DECODER_ERROR_FORMAT_CONTEXT_MAP_REPEAT = 8,
    BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_1 = 9,
    BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_2 = 10,
    BROTLI_DECODER_ERROR_FORMAT_TRANSFORM = 11,
    BROTLI_DECODER_ERROR_FORMAT_DICTIONARY = 12,
    BROTLI_DECODER_ERROR_FORMAT_WINDOW_BITS = 13,
    BROTLI_DECODER_ERROR_FORMAT_PADDING_1 = 14,
    BROTLI_DECODER_ERROR_FORMAT_PADDING_2 = 15,
    BROTLI_DECODER_ERROR_FORMAT_DISTANCE = 16,
    BROTLI_DECODER_ERROR_DICTIONARY_NOT_SET = 19,
    BROTLI_DECODER_ERROR_INVALID_ARGUMENTS = 20,
    BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MODES = 21,
    BROTLI_DECODER_ERROR_ALLOC_TREE_GROUPS = 22,
    BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MAP = 25,
    BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_1 = 26,
    BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_2 = 27,
    BROTLI_DECODER_ERROR_ALLOC_BLOCK_TYPE_TREES = 30,
    BROTLI_DECODER_ERROR_UNREACHABLE = 31,
}

/**
 * Returned by every successful (de)compression.
 */
export class BrotliStreamResult {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    /**
     * Output buffer
     */
    buf: Uint8Array;
    /**
     * Result code.
     *
     * See [`BrotliStreamResultCode`] for available values.
     *
     * When error, the error code is not passed here but rather goes to `Err`.
     */
    code: BrotliStreamResultCode;
    /**
     * Consumed bytes of the input buffer
     */
    input_offset: number;
}

/**
 * Same as [`brotli_decompressor::BrotliResult`] except [`brotli_decompressor::BrotliResult::ResultFailure`].
 *
 * Always `> 0`.
 *
 * `ResultFailure` is removed
 * because we will convert the failure to an actual negative error code (if available) and pass it elsewhere.
 */
export enum BrotliStreamResultCode {
    ResultSuccess = 1,
    NeedsMoreInput = 2,
    NeedsMoreOutput = 3,
}

/**
 * See [`BrotliDecStream`].
 *
 * For drop-in replacement of `brotli-wasm`.
 */
export class DecompressStream {
    free(): void;
    [Symbol.dispose](): void;
    decompress(input: Uint8Array, output_size: number): BrotliStreamResult;
    constructor();
    total_out(): number;
}

/**
 * No error reporting included.
 * To get the detailed error code, use [`stream::BrotliDecStream`].
 */
export function brotli_dec(input: Uint8Array): Uint8Array;

/**
 * See [`brotli_dec`].
 *
 * For drop-in replacement of `brotli-wasm`.
 */
export function decompress(buf: Uint8Array): Uint8Array;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly brotli_dec: (a: number, b: number) => [number, number, number, number];
    readonly decompress: (a: number, b: number) => [number, number, number, number];
    readonly __wbg_brotlistreamresult_free: (a: number, b: number) => void;
    readonly __wbg_get_brotlistreamresult_code: (a: number) => number;
    readonly __wbg_set_brotlistreamresult_code: (a: number, b: number) => void;
    readonly __wbg_get_brotlistreamresult_buf: (a: number) => [number, number];
    readonly __wbg_set_brotlistreamresult_buf: (a: number, b: number, c: number) => void;
    readonly __wbg_get_brotlistreamresult_input_offset: (a: number) => number;
    readonly __wbg_set_brotlistreamresult_input_offset: (a: number, b: number) => void;
    readonly __wbg_brotlidecstream_free: (a: number, b: number) => void;
    readonly brotlidecstream_new: () => number;
    readonly brotlidecstream_dec: (a: number, b: number, c: number, d: number) => [number, number, number];
    readonly brotlidecstream_decompress: (a: number, b: number, c: number, d: number) => [number, number, number];
    readonly brotlidecstream_total_out: (a: number) => number;
    readonly __wbg_decompressstream_free: (a: number, b: number) => void;
    readonly decompressstream_new: () => number;
    readonly decompressstream_decompress: (a: number, b: number, c: number, d: number) => [number, number, number];
    readonly decompressstream_total_out: (a: number) => number;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
