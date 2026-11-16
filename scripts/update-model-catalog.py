#!/usr/bin/env python3
"""Refresh the checked-in, pinned offline model catalog (network only at development time).
Small repository files are hashed here; weights use their published LFS SHA-256.
Moonshine's pinned v0.1.6 dependency catalog is read from build/research/moonshine-catalog.txt.
"""
import concurrent.futures, hashlib, json, pathlib, subprocess, urllib.request
ROOT=pathlib.Path(__file__).resolve().parent.parent
catalog_path=ROOT/'build/research/moonshine-catalog.txt'
if not catalog_path.exists():
    catalog_path.parent.mkdir(parents=True,exist_ok=True)
    executable=ROOT/'build/research/moonshine-catalog'
    subprocess.run(['clang',str(ROOT/'scripts/moonshine-catalog.c'),'-I',str(ROOT/'Frameworks/Moonshine.xcframework/macos-arm64_x86_64/Headers'),'-L',str(ROOT/'Frameworks/Moonshine.xcframework/macos-arm64_x86_64'),'-lmoonshine','-lc++','-framework','Accelerate','-framework','Foundation','-o',str(executable)],check=True)
    catalog_path.write_bytes(subprocess.check_output([str(executable)]))
out=[]
def hf(identifier,title,family,repo,files,live=False,detail='',feature=80,arch=None):
    cache=ROOT/'build/research/manifests'/f'{repo.split("/")[-1]}.json'
    data=json.loads(cache.read_text()) if cache.exists() else json.load(urllib.request.urlopen(f'https://huggingface.co/api/models/{repo}?blobs=true'))
    revision=data['sha'];siblings={f['rfilename']:f for f in data['siblings']};assets=[]
    for role,name in files.items():
        f=siblings[name];url=f'https://huggingface.co/{repo}/resolve/{revision}/{name}'
        digest=f.get('lfs',{}).get('sha256')
        if not digest: digest=hashlib.sha256(urllib.request.urlopen(url).read()).hexdigest()
        assets.append(dict(role=role,path=name,url=url,size=f['size'],checksum=digest,checksumType='sha256'))
    return dict(id=identifier,title=title,family=family,live=live,detail=detail,featureDim=feature,source=f'https://huggingface.co/{repo}',license='See model card',files=assets)
# All sizes are actual retained files, not compressed archive sizes.
for line in (ROOT/'build/research/moonshine-catalog.txt').read_text().splitlines():
    arch,raw=line.split('\t',1);arch=int(arch);data=json.loads(raw)
    if arch in (0,1): continue # Upstream legacy CDN URLs currently return 403; newer streaming models remain available.
    names={0:('moonshineTinyLegacy','Moonshine Tiny · legacy'),1:('moonshineBaseLegacy','Moonshine Base · legacy'),2:('moonshineTiny','Moonshine Tiny Streaming'),4:('moonshineSmall','Moonshine Small Streaming'),5:('moonshineMedium','Moonshine Medium Streaming')}
    identifier,title=names[arch];assets=[]
    for g in data['groups']:
        for f in g['files']:
            assets.append(dict(role=f['name'],path=f['name'],url=f.get('url',g['base_url']+'/'+f['name']),size=f['size'],checksum=f['checksum'],checksumType=f['checksum_type']))
    out.append(dict(id=identifier,title=title,family='moonshine',live=arch>1,detail=('Recommended first comparison. English, incremental captions.' if arch==4 else 'English. Larger models need more memory and processing time.' if arch==5 else 'English. Compact streaming option.' if arch==2 else 'English. Utterance-based model for saved recordings.'),featureDim=80,arch=arch,source='https://github.com/moonshine-ai/moonshine',license='MIT',files=assets))
trans={'encoder':'encoder.int8.onnx','decoder':'decoder.int8.onnx','joiner':'joiner.int8.onnx','tokens':'tokens.txt'}
specs=[
('zipformer','Zipformer · original','transducer','csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26',{'encoder':'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx','decoder':'decoder-epoch-99-avg-1-chunk-16-left-128.onnx','joiner':'joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx','tokens':'tokens.txt'},True,'Optional English streaming model.',80),
('zipformerKroko','Zipformer Kroko','transducer','csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06',{'encoder':'encoder.onnx','decoder':'decoder.onnx','joiner':'joiner.onnx','tokens':'tokens.txt'},True,'Compact alternative English checkpoint.',80),
('fastConformerCTC','FastConformer CTC','nemoCTC','csukuangfj/sherpa-onnx-nemo-streaming-fast-conformer-ctc-en-80ms-int8',{'model':'model.int8.onnx','tokens':'tokens.txt'},True,'English streaming, INT8. Compare accuracy with the transducer version.',80),
('fastConformer','FastConformer Transducer','transducer','csukuangfj/sherpa-onnx-nemo-streaming-fast-conformer-transducer-en-80ms-int8',trans,True,'English streaming, INT8.',80),
('nemotron','Nemotron Streaming 0.6B','transducer','csukuangfj2/sherpa-onnx-nemotron-speech-streaming-en-0.6b-160ms-int8-2026-04-25',trans,True,'Experimental on older phones. Large INT8 English streaming model; may not keep up.',128),
('parakeetV2','Parakeet TDT v2','offlineTransducer','csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8',trans,False,'English, INT8. Saved-text improvement; high memory use.',128),
('parakeetV3','Parakeet TDT v3','offlineTransducer','csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8',trans,False,'Multilingual, INT8. Saved-text improvement; high memory use.',128),
('parakeetRedux','Parakeet TDT Redux','offlineTransducer','csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-redux-int8',trans,False,'Experimental multilingual second pass. ONNX INT8 conversion; high memory use.',128),
('parakeet110','Parakeet CTC 110M','offlineCTC','VocaHQ/sherpa-onnx-nemo-parakeet-tdt-ctc-110m-en-int8',{'model':'model.int8.onnx','tokens':'tokens.txt'},False,'Compact English saved-text model. INT8 ONNX export.',80),
('senseVoice','SenseVoice Small','senseVoice','csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09',{'model':'model.int8.onnx','tokens':'tokens.txt'},False,'Saved-text improvement. English, Chinese, Cantonese, Japanese and Korean.',80),
('qwen','Qwen3-ASR 0.6B','qwen','csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25',{'frontend':'conv_frontend.onnx','encoder':'encoder.int8.onnx','decoder':'decoder.int8.onnx','tokenizer/merges.txt':'tokenizer/merges.txt','tokenizer/vocab.json':'tokenizer/vocab.json','tokenizer/tokenizer_config.json':'tokenizer/tokenizer_config.json'},False,'Experimental multilingual second pass. Large download and high memory use; CPU execution.',80),
]
for identifier,title,name in [('whisperTiny','Whisper Tiny English · Q5','ggml-tiny.en-q5_1.bin'),('whisperBase','Whisper Base English · Q5','ggml-base.en-q5_1.bin'),('whisperBaseFull','Whisper Base English','ggml-base.en.bin'),('whisperSmall','Whisper Small English · Q5','ggml-small.en-q5_1.bin'),('whisperMedium','Whisper Medium English · Q5','ggml-medium.en-q5_0.bin'),('whisperTurbo','Whisper Large v3 Turbo · Q5','ggml-large-v3-turbo-q5_0.bin')]:
    specs.append((identifier,title,'whisper','ggerganov/whisper.cpp',{'model':name},False,'Saved-text improvement. Quantized for lower storage.' if 'Q5' in title else 'Saved-text improvement. Original full-precision weights.',80))
specs.append(('distilSmall','Distil-Whisper Small English','whisper','distil-whisper/distil-small.en',{'model':'ggml-distil-small.en.bin'},False,'Saved-text improvement. Distilled English Whisper.',80))
# Download just one 160-ms EOU conversion, never all latency variants.
eou=json.loads((ROOT/'build/research/manifests/parakeet-realtime-eou-120m-coreml.json').read_text())
files={x['rfilename']:x['rfilename'] for x in eou['siblings'] if x['rfilename'].startswith('160ms/') and ('.mlmodelc/' in x['rfilename'] or x['rfilename']=='160ms/vocab.json')}
specs.append(('parakeetEOU','Parakeet Realtime EOU 120M','parakeetEOU','FluidInference/parakeet-realtime-eou-120m-coreml',files,True,'English streaming. No built-in punctuation. Core ML conversion requires iOS 17+; iPhone X excluded for this option.',80))
with concurrent.futures.ThreadPoolExecutor(6) as pool:
    for m in pool.map(lambda x:hf(*x),specs): out.append(m)
# Local language model, separate from the speech engines.
repo='bartowski/SmolLM2-360M-Instruct-GGUF'
name='SmolLM2-360M-Instruct-Q4_K_M.gguf'
out.append(hf('notesAI','SmolLM2 · titles & summaries','llm',repo,{'model':name},False,'Local titles and summaries after Whisper finishes. English, 360M parameters, Q4 quantization. No server.'))
for identifier,size in [('notesQwenSmall','0.5'),('notesQwenLarge','1.5')]:
    out.append(hf(identifier,f'Qwen2.5 {size}B · notes','llm',f'bartowski/Qwen2.5-{size}B-Instruct-GGUF',{'model':f'Qwen2.5-{size}B-Instruct-Q4_K_M.gguf'},False,'Optional local notes model. Experimental on iPhone X; larger weights need more memory.'))
speaker_manifest=ROOT/'build/research/speakers.json'
if speaker_manifest.exists():
    speaker_files=[]
    for group in json.loads(speaker_manifest.read_text())['groups']:
        for f in group['files']:
            speaker_files.append(dict(role=f['name'],path=f['name'],url=f['url'],size=f['size'],checksum=f['checksum'],checksumType=f['checksum_type']))
    out.append(dict(id='speakers',title='Speaker detection · Beta',family='diarization',live=False,detail='Local speaker identification for Moonshine. Experimental.',featureDim=0,source='https://github.com/moonshine-ai/moonshine',license='See model card',files=speaker_files))
for model in out:
    if model['family']=='whisper':model['detail']='Experimental and off by default. May lag and replace correct words with mistakes. Use manually or opt in under Transcription settings.'
(ROOT/'VoiceApp/ModelCatalog.json').write_text(json.dumps(out,indent=2)+'\n')
print('Wrote',len(out),'models')
