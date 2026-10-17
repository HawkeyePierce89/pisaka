export function Header({ title }: { title: string }) {
  return (
    <header className="top">
      <div>
        <div>
          <span>{title}</span>
        </div>
      </div>
      <Icon name="x" />
      <>
        <b>bold</b> tail
      </>
    </header>
  );
}
