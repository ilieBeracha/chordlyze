"""Passage lifecycle: explicit request, leased inference, review, personal apply."""
import hashlib
import json
import wave
import numpy as np
import pytest
from fastapi.testclient import TestClient
from chordlyze_backend import auth, main, corrections
from chordlyze_backend.song_jobs import SongJobs, reset_library
from chordlyze_backend.analysis.provenance import model_metadata
from chordlyze_backend.analysis.acoustic_review import acoustic_review
from chordlyze_backend.analysis.review import matching_review
from chordlyze_backend.analysis.engine import ChordSegment, Recognition, AudioDecodeError
from chordlyze_backend.analysis import passage

H = {'Authorization': 'Bearer alice'}
W = {'Authorization': 'Bearer worker-test'}
URL = '/library/song/passage-analysis'

@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setattr(main, 'CACHE_DIR', tmp_path)
    monkeypatch.setattr(auth, 'lookup', lambda token: token)
    monkeypatch.setenv('CHORDLYZE_WORKER_TOKEN', 'worker-test')
    auth.forget_all()
    chart = {**model_metadata('ismir2019'), 'source': 'youtube', 'track_id': 'song', 'title': 'Authored test',
             'artist': 'Test', 'audio_sha256': 'a'*64, 'audio_duration': 12, 'key': 'C major',
             'chords': [{'start': 0, 'end': 4, 'label': 'C:maj'}, {'start': 4, 'end': 8, 'label': 'G:maj'},
                        {'start': 8, 'end': 12, 'label': 'C:maj'}]}
    (tmp_path/'track-song.json').write_text(json.dumps(chart))
    yield TestClient(main.app), SongJobs(tmp_path), tmp_path
    auth.forget_all()

def chart(api, user='alice'):
    return api.get('/song/song', headers={'Authorization': 'Bearer '+user}).json()['analysis']

def request(api, **values):
    return api.post(URL, headers=H, json={'start': 2, 'end': 10, 'chart_revision': chart(api)['chart_revision'], **values})

def publish(api, jobs, **values):
    job = jobs.claim()
    body = dict(track_id=job['song']['track_id'], job_id=job['id'], lease=job['lease'],
                library_generation=job['generation'], audio_sha256='a'*64,
                segments=[{'start': 2, 'end': 6, 'label': 'A:min'}, {'start': 6, 'end': 10, 'label': 'F:maj'}])
    body.update(values)
    return api.post('/internal/jobs/passage', headers=W, json=body), body

def test_complete_personal_lifecycle_and_undo(env):
    api, jobs, cache = env
    before = chart(api); original = (cache/'track-song.json').read_bytes()
    assert api.get(URL, headers=H).json() == {'job': None}
    assert not list(cache.glob('job-*.json')), 'opening never queues inference'
    pending = request(api).json()['job']
    assert request(api).json()['job']['id'] == pending['id']
    assert request(api, start=3).status_code == 409
    assert api.get(URL, headers={'Authorization':'Bearer bob'}).json()['job'] is None
    result, body = publish(api, jobs)
    assert result.status_code == 200, result.text
    assert chart(api) == before, 'publishing is a proposal, not an edit'
    assert api.post('/internal/jobs/passage', headers=W, json=body).status_code == 409
    ready = api.get(URL, headers=H).json()['job']
    assert ready['state'] == 'ready' and ready['protected_count'] == 0
    payload = {'id': ready['id'], 'chart_revision': ready['chart_revision']}
    assert api.post(URL+'/apply', headers={'Authorization':'Bearer bob'}, json=payload).status_code == 409
    response = api.post(URL+'/apply', headers=H, json=payload)
    assert response.status_code == 200, response.text
    after = response.json()['analysis']
    assert corrections.raw(after['chords']) == [
        {'start':0,'end':2,'label':'C:maj'}, {'start':2,'end':4,'label':'A:min'},
        {'start':4,'end':6,'label':'A:min'}, {'start':6,'end':8,'label':'F:maj'},
        {'start':8,'end':10,'label':'F:maj'}, {'start':10,'end':12,'label':'C:maj'}]
    assert chart(api, 'bob') == before and (cache/'track-song.json').read_bytes() == original
    assert api.post(URL+'/apply', headers=H, json=payload).json()['analysis'] == after
    assert api.get(URL, headers=H).json()['job']['state'] == 'applied'
    undo = api.patch('/library/song/chords/boundary', headers=H, json={'operation':'undo','chart_revision':after['chart_revision']})
    assert corrections.raw(undo.json()['analysis']['chords']) == corrections.raw(before['chords'])

def test_manual_edits_preserved_and_chart_change_stales_proposal(env):
    api, jobs, _ = env
    edited = api.put('/library/song/chords', headers=H, json={'chart_revision':chart(api)['chart_revision'], 'start':4,'end':8,'name':'Dm7'})
    assert edited.status_code == 200
    request(api); assert publish(api,jobs)[0].status_code == 200
    ready = api.get(URL, headers=H).json()['job']
    assert ready['protected_count'] == 1
    assert {'start':4,'end':8,'label':'D:min7'} in ready['segments']
    api.put('/library/song/chords', headers=H, json={'chart_revision':chart(api)['chart_revision'],'start':0,'end':4,'name':'Em'})
    assert api.get(URL, headers=H).json()['job']['state'] == 'stale'
    assert api.post(URL+'/apply', headers=H,json={'id':ready['id'],'chart_revision':ready['chart_revision']}).status_code == 409

@pytest.mark.parametrize('values', [{'start':-1},{'end':3},{'end':40},{'chart_revision':'bad'}, {'start':12,'end':14}])
def test_invalid_ranges_do_not_queue(env, values):
    api, _, cache = env
    assert request(api,**values).status_code == 422
    assert not list(cache.glob('job-*.json'))

@pytest.mark.parametrize('values,status', [({'audio_sha256':'b'*64},409),
    ({'segments':[{'start':2,'end':11,'label':'C:maj'}]},422),
    ({'segments':[{'start':2,'end':4,'label':'C:maj'}, {'start':5,'end':10,'label':'G:maj'}]},422),
    ({'segments':[{'start':2,'end':10,'label':'garbage'}]},422)])
def test_worker_results_validate_identity_and_exact_coverage(env,values,status):
    api,jobs,_=env
    request(api)
    assert publish(api,jobs,**values)[0].status_code == status
    assert chart(api)['can_undo'] is False

def test_reset_invalidates_proposal_and_auth_required(env):
    api,jobs,cache=env
    assert api.get(URL).status_code == 401
    request(api); _,body=publish(api,jobs)
    reset_library(cache,apply=True)
    assert api.get(URL,headers=H).json()['job'] is None
    assert api.post('/internal/jobs/passage',headers=W,json=body).status_code == 409

def test_acoustic_rankings_and_stale_evidence():
    names=['C:maj','A:min','G:maj','N']
    obs=np.array([[0,-.1,-3,-4],[0,-.1,-3,-4],[-5,0,-3,-4],[-5,0,-3,-4]])
    result=acoustic_review([(0,2,'C:maj'),(2,4,'C:maj')],names,obs,1)
    assert result[0]['needs_review'] and result[0]['alternatives'][0]=='A:min'
    assert result[1]['reason']=='Acoustic evidence disagrees'
    clear=acoustic_review([(2,4,'A:min')],names,obs,1)[0]
    assert not clear['needs_review'] and 'confidence' not in clear
    assert matching_review(result,[dict(start=0,end=2,label='C:maj')])==result[:1]
    assert matching_review(result,[dict(start=0,end=2,label='F:maj')])==[]
    assert acoustic_review([(20,21,'C:maj')], names,obs,1)==[]

def test_crop_context_timing_and_hash(tmp_path,monkeypatch):
    source=tmp_path/'authored.wav'
    samples=(np.sin(np.arange(44100*20)*.1)*8000).astype('<i2').tobytes()
    with wave.open(str(source),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(44100);f.writeframes(samples)
    import shutil
    monkeypatch.setattr(passage,'_decode_to_wav',lambda src,dst:shutil.copyfile(src,dst))
    calls=[]
    def recognize(path,**kwargs):
        with wave.open(str(path),'rb') as f: assert f.getnframes()/f.getframerate()==12
        calls.append(kwargs)
        return Recognition([ChordSegment(0,6,'C:maj'),ChordSegment(6,12,'G:maj')],12,'b'*64,'ismir2019',[])
    monkeypatch.setattr(passage,'recognize_audio',recognize)
    job={'audio_sha256':hashlib.sha256(samples).hexdigest(),'start':8,'end':12}
    result=passage.recognize_passage(source,job)
    assert result['segments']==[dict(start=8,end=10,label='C:maj'),dict(start=10,end=12,label='G:maj')]
    assert calls[0]['review'] and calls[0]['passage']
    with pytest.raises(AudioDecodeError,match='does not match'):
        passage.recognize_passage(source,{**job,'audio_sha256':'a'*64})
    assert len(calls)==1, 'wrong recording must never enter inference'


def test_passage_review_survives_split_boundaries_and_undo(env):
    api,jobs,_=env
    request(api)
    cue=dict(start=2,end=6,label='A:min',alternatives=['C:maj'],needs_review=True,reason='Close alternatives')
    result,_=publish(api,jobs,chord_review=[cue])
    assert result.status_code==200
    ready=api.get(URL,headers=H).json()['job']
    applied=api.post(URL+'/apply',headers=H,json={'id':ready['id'],'chart_revision':ready['chart_revision']}).json()['analysis']
    assert [(r['start'],r['end']) for r in applied['chord_review']]==[(2,4),(4,6)]
    edited=api.put('/library/song/chords',headers=H,json={'start':2,'end':4,'name':'Em','chart_revision':applied['chart_revision']}).json()['analysis']
    assert len(edited['chord_review'])==1
    undone=api.patch('/library/song/chords/boundary',headers=H,json={'operation':'undo','chart_revision':edited['chart_revision']}).json()['analysis']
    assert undone['chord_review']==applied['chord_review']


def test_passage_worker_cleans_audio_and_does_not_publish_lyrics(env,tmp_path,monkeypatch):
    import song_worker
    api,jobs,_=env
    request(api)
    job=jobs.claim()
    audio=tmp_path/'worker.wav'; audio.write_bytes(b'fixture')
    monkeypatch.setattr(song_worker,'fetch_full_track',lambda *a,**kw:audio)
    monkeypatch.setattr(passage,'recognize_passage',lambda *a:{'audio_sha256':'a'*64,'segments':[dict(start=2,end=10,label='G:maj')],'chord_review':[]})
    class Client:
        def post(self,path,payload):
            response=api.post(path,headers=W,json=payload)
            assert response.status_code==200,response.text
            return response.json()
    assert song_worker.process_job(Client(),job)=='ready'
    assert not audio.exists()
    assert chart(api)['chords'][0]['label']=='C:maj'
    assert api.get(URL,headers=H).json()['job']['state']=='ready'


def test_boundary_edits_are_preserved_whole():
    original=[dict(start=0,end=4,label='C:maj'),dict(start=4,end=8,label='G:maj'),dict(start=8,end=12,label='C:maj')]
    current=[dict(start=0,end=5,label='C:maj'),dict(start=5,end=8,label='G:maj'),original[2]]
    from chordlyze_backend.passages import splice
    result,count=splice(current,original,[dict(start=2,end=10,label='F:maj')],2,10)
    assert count==2 and result[:2]==current[:2]
    assert result[-1]==dict(start=10,end=12,label='C:maj')


def test_cancel_invalidates_lease_and_allows_fresh_request(env):
    api,jobs,_=env
    queued=request(api).json()['job']; claimed=jobs.claim()
    url=URL+'/'+queued['id']
    assert api.delete(url,headers={'Authorization':'Bearer bob'}).status_code==409
    assert api.delete(url,headers=H).json()['job']['state']=='cancelled'
    assert not jobs.valid_lease(claimed['song']['track_id'],claimed['id'],claimed['lease'],claimed['generation'])
    replacement=request(api).json()['job']
    assert replacement['id']!=queued['id'] and replacement['state']=='queued'
    assert api.delete(url,headers=H).status_code==409, 'old screen cannot cancel new preparation'
