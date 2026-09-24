@extends('mail.layout')
@section('title', 'Подтвердите почту')
@section('content')
<p>{{ name }}, подтвердите почту: <a href="{{ link }}">подтвердить</a>.</p>
<p>Ссылка действует сутки.</p>
@endsection
