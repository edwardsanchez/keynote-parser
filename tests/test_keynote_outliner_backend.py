import zipfile

from scripts import keynote_outliner_backend


SIMPLE_FILENAME = "./tests/data/simple-oneslide.key"
SIMPLE_SLIDE_ARCHIVE = "Index/Slide-8060.iwa"


def test_load_command_includes_slide_metadata_fields(tmp_path):
    payload = keynote_outliner_backend.load_command(
        SIMPLE_FILENAME, cache_dir=str(tmp_path / "cache")
    )

    slides = payload["slides"]
    assert len(slides) == 1
    row = slides[0]

    assert row["index"] == 1
    assert row["keynoteIndex"] == 1
    assert row["isSkipped"] is False
    assert row["isEditable"] is True
    assert row["loadIssue"] is None


def test_load_command_keeps_placeholder_for_missing_slide_archive(tmp_path):
    input_path = tmp_path / "missing-slide.key"
    with zipfile.ZipFile(SIMPLE_FILENAME, "r") as src, zipfile.ZipFile(input_path, "w") as dst:
        for info in src.infolist():
            if info.filename == SIMPLE_SLIDE_ARCHIVE:
                continue
            dst.writestr(info, src.read(info.filename))

    payload = keynote_outliner_backend.load_command(
        str(input_path), cache_dir=str(tmp_path / "cache")
    )

    slides = payload["slides"]
    assert len(slides) == 1
    row = slides[0]

    assert row["index"] == 1
    assert row["keynoteIndex"] == 1
    assert row["isEditable"] is False
    assert row["loadIssue"] == "missing-slide-archive"
    assert row["noteText"] == ""
